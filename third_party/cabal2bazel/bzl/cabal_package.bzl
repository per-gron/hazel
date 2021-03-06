# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Skylark build rules for cabal haskell packages.

To see all of the generated rules, run:
bazel query --output=build @haskell_{package}_{hash}//:all
where {package} is the lower-cased package name with - replaced by _
and {hash} is the Bazel hash of the original package name.
"""
load("@bazel_skylib//:lib.bzl", "paths")
load("@io_tweag_rules_haskell//haskell:haskell.bzl",
     "haskell_library",
     "haskell_binary",
     "haskell_cc_import",
)
load("@io_tweag_rules_haskell//haskell:c2hs.bzl", "c2hs_library")
load(":bzl/alex.bzl", "genalex")
load(":bzl/cabal_paths.bzl", "cabal_paths")
load(":bzl/happy.bzl", "genhappy")
load("//templates:templates.bzl", "templates")
load("//tools:mangling.bzl", "hazel_library")

_conditions_default = "//conditions:default"

# Include files that are exported by core dependencies
# (That is, their "install-includes".)
# TODO: detect this more automatically.
_CORE_DEPENDENCY_INCLUDES = {
    "unix": "@ghc//:unix-includes",
}

def _paths_module(desc):
  return "Paths_" + desc.package.pkgName.replace("-","_")

def _hazel_symlink_impl(ctx):
  ctx.actions.run(
      outputs=[ctx.outputs.out],
      inputs=[ctx.file.src],
      executable="ln",
      arguments=["-s",
                  "/".join([".."] * len(ctx.outputs.out.dirname.split("/")))
                    + "/" + ctx.file.src.path,
                  ctx.outputs.out.path])

hazel_symlink = rule(
    implementation = _hazel_symlink_impl,
    attrs = {
        "src": attr.label(mandatory=True, allow_files=True, single_file=True),
        "out": attr.string(mandatory=True),
    },
    outputs={"out": "%{out}"})

def _conditions_dict(d):
  return d.select if hasattr(d, "select") else {_conditions_default: d}

def _fix_source_dirs(dirs):
  if dirs:
    return dirs
  return [""]

def _module_output(file, ending):
  """Replace the input's ending by the ending for the generated output file.

  Args:
    file: Input file name.
    ending: Input file ending.

  Returns:
    The output file with appropriate ending. E.g. `file.y --> file.hs`.
  """
  out_extension = {
    "hs": "hs",
    "lhs": "lhs",
    "hsc": "hsc",
    "chs": "hs",
    "x": "hs",
    "y": "hs",
    "ly": "hs",
  }[ending]
  return file[:-len(ending)] + out_extension

def _find_module_by_ending(modulePath, ending, sourceDirs):
  """Try to find a source file for the given modulePath with the given ending.

  Checks for module source files in all given source directories.

  Args:
    modulePath: The module path converted to a relative file path. E.g.
      `Some/Module/Name`
    ending: Look for module source files with this file ending.
    sourceDirs: Look for module source files in these directories.

  Returns:
    Either `None` if no source file was found, or a `struct` describing the
    module source file. See `_find_module` for details.
  """
  # Find module source file in source directories.
  files = native.glob([
    paths.join(d if d != "." else "", modulePath + "." + ending)
    for d in sourceDirs
  ])
  if len(files) == 0:
    return None
  file = files[0]
  # Look for hs/lhs boot file.
  bootFile = None
  if ending in ["hs", "lhs"]:
    bootFiles = native.glob([file + "-boot"])
    if len(bootFiles) != 0:
      bootFile = bootFiles[0]
  return struct(
    type = ending,
    src = file,
    out = _module_output(file, ending),
    boot = bootFile,
  )

def _find_module(module, sourceDirs):
  """Find the source file for the given module.

  Args:
    module: Find the source file for this module. E.g. `Some.Module.Name`.
    sourceDirs: List of source directories under which to search for sources.

  Returns:
    Either `None` if no module source file was found,
    or a `struct` with the following fields:

    `type`: The ending.
    `src`: The source file that was found.
      E.g. `Some/Module/Name.y`
    `out`: The expected generated output module file.
      E.g. `Some/Module/Name.hs`.
    `bootFile`: Haskell boot file path or `None` if no boot file was found.
  """
  modulePath = module.replace(".", "/")
  mod = None
  # Looking for raw source files first. To override duplicates (e.g. if a
  # package contains both a Happy Foo.y file and the corresponding generated
  # Foo.hs).
  for ending in ["hs", "lhs", "hsc", "chs", "x", "y", "ly"]:
    mod = _find_module_by_ending(modulePath, ending, sourceDirs)
    if mod != None:
      break
  return mod

def _get_build_attrs(
    name,
    build_info,
    desc,
    generated_srcs_dir,
    extra_modules,
    ghc_version,
    extra_libs,
    extra_libs_hdrs,
    extra_libs_strip_include_prefix,
    cc_deps=[],
    version_overrides=None,
    ghcopts=[]):
  """Get the attributes for a particular library or binary rule.

  Args:
    name: The name of this component.
    build_info: A struct of the Cabal BuildInfo for this component.
    desc: A struct of the Cabal PackageDescription for this package.
    generated_srcs_dir: Location of autogenerated files for this rule,
      e.g., "dist/build" for libraries.
    extra_modules: exposed-modules: or other-modules: in the package description
    extra_libs: A dictionary that maps from name of extra libraries to Bazel
      targets that provide the shared library.
    extra_libs_hdrs: Similar to extra_libs, but provides header files.
    extra_libs_strip_include_prefix: Similar to extra_libs, but allows to
      get include prefix to strip.
    cc_deps: External cc_libraries that this rule should depend on.
    version_overrides: Override the default version of specific dependencies;
      see cabal_haskell_package for more details.
    ghcopts: Extra GHC options.
  Returns:
    A dictionary of attributes (e.g. "srcs", "deps") that can be passed
    into a haskell_library or haskell_binary rule.
  """

  # Preprocess and collect all the source files by their extension.
  # module_map will contain a dictionary from module names ("Foo.Bar")
  # to the preprocessed source file ("src/Foo/Bar.hs").
  module_map = {}
  # boot_module_map will contain a dictionary from module names ("Foo.Bar")
  # to hs-boot files, if applicable.
  boot_module_map = {}
  # build_files will contain a list of all files in the build directory.
  build_files = []

  srcs_dir = "gen-srcs-" + name + "/"
  clib_name = name + "-cbits"
  generated_modules = [_paths_module(desc)]

  # Keep track of chs modules, as later chs modules may depend on earlier ones.
  chs_targets = []

  for module in build_info.otherModules + extra_modules:
    if module in generated_modules:
      continue

    # Look for module files in source directories.
    info = _find_module(module,
      _fix_source_dirs(build_info.hsSourceDirs) + [generated_srcs_dir]
    )
    if info == None:
      fail("Missing module %s for %s" % (module, name) + str(module_map))

    # Create module files in build directory.
    symlink_name = name + "-" + module + "-symlink"
    if info.type in ["hs", "lhs", "hsc"]:
      module_out = srcs_dir + info.out
      module_map[module] = module_out
      build_files.append(module_out)
      hazel_symlink(
        name = symlink_name,
        src = info.src,
        out = module_out,
      )
      if info.boot != None:
        boot_out = srcs_dir + info.out + "-boot"
        boot_module_map[module] = boot_out
        build_files.append(boot_out)
        hazel_symlink(
          name = name + "-boot-" + module + "-symlink",
          src = info.boot,
          out = boot_out,
        )
    elif info.type in ["chs"]:
      chs_name = name + "-" + module + "-chs"
      module_map[module] = chs_name
      build_files.append(srcs_dir + info.src)
      hazel_symlink(
        name = symlink_name,
        src = info.src,
        out = srcs_dir + info.src,
      )
      c2hs_library(
        name = chs_name,
        srcs = [symlink_name],
        deps = [
          _haskell_cc_import_name(elib)
          for elib in build_info.extraLibs
        ] + [clib_name] + chs_targets,
      )
      chs_targets.append(chs_name)
    elif info.type in ["x"]:
      module_out = srcs_dir + info.out
      module_map[module] = module_out
      build_files.append(module_out)
      genalex(
        src = info.src,
        out = module_out,
      )
    elif info.type in ["y", "ly"]:
      module_out = srcs_dir + info.out
      module_map[module] = module_out
      build_files.append(module_out)
      genhappy(
        src = info.src,
        out = module_out,
      )

  # Create extra source files in build directory.
  extra_srcs = []
  for f in native.glob([paths.normalize(f) for f in desc.extraSrcFiles]):
    fout = srcs_dir + f
    # Skip files that were created in the previous steps.
    if fout in build_files:
      continue
    hazel_symlink(
      name = fout + "-symlink",
      src = f,
      out = srcs_dir + f,
    )
    extra_srcs.append(fout)

  # Collect the source files for each module in this Cabal component.
  # srcs is a mapping from "select()" conditions (e.g. //third_party/haskell/ghc:ghc-8.0.2) to a list of source files.
  # Turn others to dicts if there is a use case.
  srcs = {}
  # Keep track of .hs-boot files specially.  GHC doesn't want us to pass
  # them as command-line arguments; instead, it looks for them next to the
  # corresponding .hs files.
  deps = {}
  cdeps = []
  paths_module = _paths_module(desc)
  extra_modules_dict = _conditions_dict(extra_modules)
  other_modules_dict = _conditions_dict(build_info.otherModules)
  for condition in depset(extra_modules_dict.keys() + other_modules_dict.keys()):
    srcs[condition] = []
    deps[condition] = []
    for m in (extra_modules_dict.get(condition, []) +
              other_modules_dict.get(condition, [])):
      if m == paths_module:
        deps[condition] += [":" + paths_module]
      elif m in module_map:
        srcs[condition] += [module_map[m]]
        # Get ".hs-boot" and ".lhs-boot" files.
        if m in boot_module_map:
          srcs[condition] += [boot_module_map[m]]
      else:
        fail("Missing module %s for %s" % (m, name) + str(module_map))

  # Collect the options to pass to ghc.
  extra_ghcopts = ghcopts
  ghcopts = []
  all_extensions = [ ext for ext in
                     ([build_info.defaultLanguage]
                      if build_info.defaultLanguage else ["Haskell98"])
                     + build_info.defaultExtensions
                     + build_info.oldExtensions ]
  ghcopts = ghcopts + ["-X" + ext for ext in all_extensions]

  ghcopt_blacklist = ["-Wall","-Wwarn","-w","-Werror", "-O2", "-O", "-O0"]
  for (compiler,opts) in build_info.options:
    if compiler == "ghc":
      ghcopts += [o for o in opts if o not in ghcopt_blacklist]
  ghcopts += ["-w", "-Wwarn"]  # -w doesn't kill all warnings...

  # Collect the dependencies.
  for condition, ps in _conditions_dict(depset(
      [p.name for p in build_info.targetBuildDepends]).to_list()).items():
    if condition not in deps:
      deps[condition] = []
    for p in ps:
      deps[condition] += [hazel_library(p)]
      if p in _CORE_DEPENDENCY_INCLUDES:
        cdeps += [_CORE_DEPENDENCY_INCLUDES[p]]
        deps[condition] += [_CORE_DEPENDENCY_INCLUDES[p]]

  ghcopts += ["-optP" + o for o in build_info.cppOptions]

  # Generate a cc_library for this package.
  # TODO(judahjacobson): don't create the rule if it's not needed.
  # TODO(judahjacobson): Figure out the corner case logic for some packages.
  # In particular: JuicyPixels, cmark, ieee754.
  install_includes = native.glob(
      [paths.join(d, f) for d in build_info.includeDirs
       for f in build_info.installIncludes])
  headers = depset(
      native.glob([paths.normalize(f) for f in desc.extraSrcFiles + desc.extraTmpFiles])
      + install_includes)
  ghcopts += ["-I" + native.package_name() + "/" + d for d in build_info.includeDirs]
  for xs in deps.values():
    xs.append(":" + clib_name)

  ghc_version_components = ghc_version.split(".")
  ghc_version_string = (
      ghc_version_components[0] +
      ("0" if int(ghc_version_components[1]) <= 9 else "")
      + ghc_version_components[1])

  elibs_targets = []
  elibs_includes = []

  for elib in build_info.extraLibs:
    elib_target_name = elib + "-cc-import"

    native.cc_import(
      name = elib_target_name,
      shared_library = extra_libs[elib],
      hdrs = [extra_libs_hdrs[elib]] if elib in extra_libs_hdrs else [],
    )
    elibs_targets.append(":" + elib_target_name)

    if elib in extra_libs_strip_include_prefix:
      i = extra_libs_strip_include_prefix[elib]
      if i[0] == '/':
        i = i[1:]

      elibs_includes.append(i)

  native.cc_library(
      name = clib_name,
      srcs = build_info.cSources,
      includes = build_info.includeDirs,
      copts = ([o for o in build_info.ccOptions if not o.startswith("-D")]
               + ["-D__GLASGOW_HASKELL__=" + ghc_version_string,
                  "-w",
                 ]
               + ["-I" + i for i in elibs_includes]),
      defines = [o[2:] for o in build_info.ccOptions if o.startswith("-D")],
      textual_hdrs = list(headers),
      deps = ["@ghc//:threaded-rts"] + cdeps + cc_deps + elibs_targets,
  )

  return {
      "srcs": srcs,
      "extra_srcs": extra_srcs,
      "deps": deps,
      "compiler_flags": ghcopts + extra_ghcopts,
      "src_strip_prefix": srcs_dir,
  }

def _collect_data_files(description):
  name = description.package.pkgName
  if name in templates:
    files = []
    for f in templates[name]:
      out = paths.join(description.dataDir, f)
      hazel_symlink(
          name = name + "-template-" + f,
          src = "@ai_formation_hazel//templates/" + name + ":" + f,
          out = out)
      files += [out]
    return files
  else:
    return native.glob([paths.join(description.dataDir, d) for d in description.dataFiles])

def _haskell_cc_import_name(clib_name):
  return clib_name + "-haskell-cc-import"

def cabal_haskell_package(
    description,
    ghc_version,
    extra_libs,
    extra_libs_hdrs,
    extra_libs_strip_include_prefix,
    ):
  """Create rules for building a Cabal package.

  Args:
    description: A Skylark struct generated by cabal2build representing a
      .cabal file's contents.
    extra_libs: A dictionary that maps from name of extra libraries to Bazel
      targets that provide the shared library.
    extra_libs_hdrs: Similar to extra_libs, but provides header files.
    extra_libs_strip_include_prefix: Similar to extra_libs, but allows to
      get include prefix to strip.
  """
  name = description.package.pkgName

  cabal_paths(
      name = _paths_module(description),
      package = name.replace("-","_"),
      version = [int(v) for v in description.package.pkgVersion.split(".")],
      data_dir = description.dataDir,
      data = _collect_data_files(description),
  )

  lib = description.library
  if lib and lib.libBuildInfo.buildable:
    if not lib.exposedModules:
      native.cc_library(
          name = name,
          visibility = ["//visibility:public"],
      )
    else:
      lib_attrs = _get_build_attrs(
        name,
        lib.libBuildInfo,
        description,
        "dist/build",
        lib.exposedModules,
        ghc_version,
        extra_libs,
        extra_libs_hdrs,
        extra_libs_strip_include_prefix,
      )
      srcs = lib_attrs.pop("srcs")
      deps = lib_attrs.pop("deps")

      elibs_targets = []

      for elib in lib.libBuildInfo.extraLibs:
        elib_target_name = _haskell_cc_import_name(elib)
        haskell_cc_import(
          name = elib_target_name,
          shared_library = extra_libs[elib],
          hdrs = [extra_libs_hdrs[elib]] if elib in extra_libs_hdrs else [],
          strip_include_prefix = extra_libs_strip_include_prefix[elib]
                      if elib in extra_libs_strip_include_prefix else "",
        )
        elibs_targets.append(":" + elib_target_name)

      hidden_modules = [m for m in lib.libBuildInfo.otherModules if not m.startswith("Paths_")]

      haskell_library(
          name = name,
          srcs = select(srcs),
          hidden_modules = hidden_modules,
          version = description.package.pkgVersion,
          deps = select(deps) + elibs_targets,
          visibility = ["//visibility:public"],
          **lib_attrs
      )

  for exe in description.executables:
    if not exe.buildInfo.buildable:
      continue
    exe_name = exe.exeName
    # Avoid a name clash with the library.  For stability, make this logic
    # independent of whether the package actually contains a library.
    if exe_name == name:
      exe_name = name + "_bin"
    paths_mod = _paths_module(description)
    attrs = _get_build_attrs(
      exe_name,
      exe.buildInfo,
      description,
      "dist/build/%s/%s-tmp" % (name, name),
      # Some packages (e.g. happy) don't specify the Paths_ module
      # explicitly.
      [paths_mod] if paths_mod not in exe.buildInfo.otherModules else [],
      ghc_version,
      extra_libs,
      extra_libs_hdrs,
      extra_libs_strip_include_prefix,
    )
    srcs = attrs.pop("srcs")
    deps = attrs.pop("deps")

    [full_module_path] = native.glob(
        [paths.normalize(paths.join(d, exe.modulePath)) for d in _fix_source_dirs(exe.buildInfo.hsSourceDirs)])
    full_module_out = paths.join(attrs["src_strip_prefix"], full_module_path)
    existing = native.existing_rules()
    if not [existing[k] for k in existing if "out" in existing[k]
            and existing[k]["out"] == full_module_out]:
      hazel_symlink(
          name = exe_name + "-" + exe.modulePath,
          src = full_module_path,
          out = full_module_out,
      )
    for xs in srcs.values():
      if full_module_out not in xs:
        xs.append(full_module_out)

    haskell_binary(
        name = exe_name,
        srcs = select(srcs),
        deps = select(deps),
        linkstatic = False,
        visibility = ["//visibility:public"],
        **attrs
    )
