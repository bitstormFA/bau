import std/[json, os, options, strutils, tables]
import bau/[config, configedit, features, metadata, packaging, taskcache,
  taskgraph, testexec, toolchain]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block parse_new_config_fields:
  let cfg = parseBauConfig("""
[package]
name = "demo"
version = "0.2.0"
include = ["src/**"]
exclude = ["src/private.nim"]

[toolchain]
nim = ">=2.2"
atlas = ">=0.8"

[dependencies]
parsetoml = ">=0.6.0"

[patch]
parsetoml = { path = "../parsetoml" }

[[tasks]]
name = "gen"
cmd = "nim r scripts/gen.nims"
description = "Generate files"
deps = ["build"]
inputs = ["schema/*.json"]
outputs = ["src/generated.nim"]
shell = "sh"
cache = true
envInputs = ["GEN_MODE"]
requiredFeatures = ["docs"]

[[buildScripts]]
name = "gen-version"
cmd = "nim r scripts/gen_version.nims"
inputs = ["scripts/gen_version.nims"]
outputs = ["src/version.nim"]

[catalog]
parsetoml = ">=0.6.0"

[features]
default = ["docs"]
docs = []

[governance]
blocked = ["badpkg"]
trusted = ["parsetoml"]
minimumReleaseAgeHours = 24
""")

  doAssert cfg.package.includeFiles == @["src/**"]
  doAssert cfg.package.excludeFiles == @["src/private.nim"]
  doAssert cfg.toolchain.nim == ">=2.2"
  doAssert cfg.toolchain.atlas == ">=0.8"
  doAssert cfg.patches["parsetoml"].path == some("../parsetoml")
  doAssert cfg.tasks[0].description == "Generate files"
  doAssert cfg.tasks[0].inputs == @["schema/*.json"]
  doAssert cfg.tasks[0].outputs == @["src/generated.nim"]
  doAssert cfg.tasks[0].shell == "sh"
  doAssert cfg.tasks[0].cache
  doAssert cfg.tasks[0].envInputs == @["GEN_MODE"]
  doAssert cfg.tasks[0].requiredFeatures == @["docs"]
  doAssert cfg.buildScripts[0].name == "gen-version"
  doAssert cfg.catalogs["default"]["parsetoml"] == ">=0.6.0"
  doAssert cfg.features["default"].enables == @["docs"]
  doAssert cfg.governance.blocked == @["badpkg"]

block workspace_defaults_and_root_patch:
  let tmp = getTempDir() / "bau-test-workspace-defaults"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[workspace]
members = ["apps/demo"]
defaultMembers = ["apps/demo"]

[workspace.package]
version = "1.2.3"
license = "MIT"

[workspace.dependencies]
shared = ">=1.0"

[workspace.profile.dev]
flags = ["--debugInfo:on"]

[workspace.catalog]
shared = ">=1.0"

[patch]
shared = { path = "vendor/shared" }
""")
  write(tmp / "apps" / "demo" / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/demo.nim"
""")

  let cfg = loadEffectiveConfig(tmp / "apps" / "demo", tmp)
  doAssert cfg.package.version == "1.2.3"
  doAssert cfg.package.license == "MIT"
  doAssert cfg.deps["shared"].path == some("vendor/shared")
  doAssert cfg.catalogs["default"]["shared"] == ">=1.0"
  doAssert cfg.profiles.hasKey("dev")

block feature_resolution_and_optional_deps:
  let cfg = parseBauConfig("""
[package]
name = "demo"

[catalog]
base = ">=1.0"

[dependencies]
base = "catalog:"
sqlite = { version = ">=3.0", optional = true }

[features]
default = ["cli"]
cli = ["dep:sqlite"]
""")

  doAssert cfg.deps["base"].version == some(">=1.0")
  doAssert cfg.deps["sqlite"].optional
  let selection = resolveFeatures(cfg, @[])
  doAssert selection.enabled == @["cli"]
  doAssert selection.enabledDeps == @["sqlite"]
  doAssert dependencyEnabled(cfg, "sqlite", cfg.deps["sqlite"], selection)
  doAssert "-d:cli" in compilerFeatureFlags(selection)

block test_matrix_uses_configured_profiles:
  var cfg = initBauConfig()
  cfg.test.profiles = @["dev", "release", "danger"]
  doAssert effectiveTestProfiles(cfg, "dev") == @["dev", "release", "danger"]
  doAssert parseTestOutputMode("always") == tomAlways

block package_collects_include_exclude:
  let tmp = getTempDir() / "bau-test-package-files"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "src" / "demo.nim", "discard\n")
  write(tmp / "src" / "private.nim", "discard\n")
  write(tmp / "build" / "ignored", "ignored\n")

  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.package.version = "0.1.0"
  cfg.package.includeFiles = @["src"]
  cfg.package.excludeFiles = @["src/private.nim"]

  doAssert collectPackageFiles(tmp, cfg) == @["src/demo.nim"]

block task_graph_dry_run_with_deps:
  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.tasks.add(TaskInfo(name: "prepare", cmd: "echo prepare"))
  cfg.tasks.add(TaskInfo(name: "docs", cmd: "echo docs", deps: @["prepare"]))

  let opts = TaskRunOptions(profile: "dev", dryRun: true)
  doAssert runTaskByName(cfg, "docs", getTempDir(), opts)

block task_args_are_opt_in_and_exposed:
  let tmp = getTempDir() / "bau-test-task-args"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)
  createDir(tmp)

  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.tasks.add(TaskInfo(
    name: "fetch",
    cmd: "printf %s \"$BAU_TASK_ARG_0\" > out.txt",
    shell: "sh",
    acceptArgs: true))

  let opts = TaskRunOptions(profile: "dev", taskArgs: @["cpu"])
  doAssert runTaskByName(cfg, "fetch", tmp, opts)
  doAssert readFile(tmp / "out.txt") == "cpu"

block task_args_rejected_by_default:
  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.tasks.add(TaskInfo(name: "plain", cmd: "echo plain"))

  var raised = false
  try:
    discard runTaskByName(cfg, "plain", getTempDir(), TaskRunOptions(
      profile: "dev",
      taskArgs: @["extra"]))
  except ValueError:
    raised = true
  doAssert raised

block task_cache_roundtrip:
  let tmp = getTempDir() / "bau-test-task-cache"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "input.txt", "input\n")
  write(tmp / "out" / "result.txt", "result\n")

  var cfg = initBauConfig()
  cfg.cache.dir = ".cache"
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out/result.txt"])
  let entry = taskCacheEntry(task, tmp, cfg, "dev")
  saveTaskOutputs(entry, task, tmp)
  removeFile(tmp / "out" / "result.txt")
  doAssert restoreTaskOutputs(entry, tmp)
  doAssert readFile(tmp / "out" / "result.txt") == "result\n"

block deps_patch_entry:
  let tmp = getTempDir() / "bau-test-deps-patch"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[dependencies]
shared = ">=1.0"
""")
  writePatchEntry(tmp, "shared", "../shared")
  let cfg = parseBauConfigFile(tmp / "bau.toml")
  doAssert cfg.patches["shared"].path == some("../shared")

block dependency_edit_preserves_sections_and_full_shape:
  let tmp = getTempDir() / "bau-test-dependency-edit"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[dependencies]
foo = ">=1.0"
foobar = ">=9.0"

[[tasks]]
name = "docs"
cmd = "nim doc"
""")

  addDependency(tmp, DependencyEdit(
    name: "foo",
    git: "https://example.com/foo.git",
    branch: "main",
    rev: "abc123",
    optional: true))
  addDependency(tmp, DependencyEdit(
    name: "sqlite",
    registry: "internal",
    version: ">=3.0",
    optional: true))

  let content = readFile(tmp / "bau.toml")
  doAssert content.contains("foo = { git = \"https://example.com/foo.git\", branch = \"main\", rev = \"abc123\", optional = true }")
  doAssert content.contains("foobar = \">=9.0\"")
  doAssert content.find("sqlite") < content.find("[[tasks]]")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  doAssert cfg.deps["foo"].url == some("https://example.com/foo.git")
  doAssert cfg.deps["foo"].branch == some("main")
  doAssert cfg.deps["foo"].rev == some("abc123")
  doAssert cfg.deps["foo"].optional
  doAssert cfg.deps["sqlite"].registry == some("internal")
  doAssert cfg.deps["sqlite"].version == some(">=3.0")
  doAssert cfg.deps["sqlite"].optional

block toolchain_version_constraints:
  doAssert versionSatisfies("2.2.10", ">=2.2")
  doAssert versionSatisfies("2.2.10", "<3.0")
  doAssert not versionSatisfies("2.0.0", ">=2.2")

block metadata_and_query:
  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.package.version = "0.1.0"
  cfg.build.output = "demo"
  cfg.deps["shared"] = DepInfo(version: some(">=1.0"))
  cfg.targets.add(TargetInfo(name: "demo", kind: bkBin, main: "src/demo.nim"))
  cfg.tasks.add(TaskInfo(name: "docs", cmd: "nim doc", deps: @["build"]))

  let meta = configMetadataJson(cfg, getTempDir())
  doAssert meta["formatVersion"].getInt() == 1
  doAssert meta["package"]["name"].getStr() == "demo"
  doAssert queryDeps(cfg, "demo") == @["shared"]
  doAssert queryWhy(cfg, "shared").contains("direct package dependency")
  let graph = graphJson(cfg)
  var ids = initTable[string, bool]()
  for node in graph["nodes"].getElems():
    let id = node["id"].getStr()
    doAssert not ids.hasKey(id)
    ids[id] = true
