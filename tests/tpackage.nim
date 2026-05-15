import std/[json, options, os, sequtils, strutils, tables]
import bau/[build, command, config, features, fingerprint, lock, metadata, ops,
  packaging, util]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block nimble_content_and_publish_override_detection:
  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.package.version = "0.1.0"
  cfg.package.description = "Demo package"
  cfg.package.license = "MIT"
  cfg.build.kind = bkBin
  cfg.build.output = "demo"
  cfg.toolchain.nim = ">=2.2"
  cfg.deps["parsetoml"] = DepInfo(version: some(">=0.6.0"))
  cfg.deps["sat"] = DepInfo()

  let content = nimbleContent(cfg)
  doAssert "version" in content
  doAssert "bin" in content
  doAssert "requires \"nim >=2.2\"" in content
  doAssert "requires \"parsetoml >=0.6.0\"" in content
  doAssert "requires \"sat\"" in content
  doAssert not hasLocalPublishOverrides(cfg)

  cfg.deps["local"] = DepInfo(path: some("../local"))
  doAssert hasLocalPublishOverrides(cfg)

block compile_commands_are_recursive_and_include_tests:
  let tmp = getTempDir() / "bau-test-compile-commands"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/demo.nim"
output = "demo"
""")
  write(tmp / "src" / "demo.nim", "discard\n")
  write(tmp / "src" / "nested" / "extra.nim", "discard\n")
  write(tmp / "tests" / "tdemo.nim", "doAssert true\n")

  generateCompileCommands(tmp, "dev")
  let entries = parseJson(readFile(tmp / "compile_commands.json"))
  var files: seq[string]
  for entry in entries.getElems():
    files.add(entry["file"].getStr().replace("\\", "/"))
  doAssert files.anyIt(it.endsWith("src/demo.nim"))
  doAssert files.anyIt(it.endsWith("src/nested/extra.nim"))
  doAssert files.anyIt(it.endsWith("tests/tdemo.nim"))

block target_plan_uses_target_output_and_paths:
  var cfg = initBauConfig()
  cfg.package.name = "demo"
  cfg.build.source = "src"
  cfg.targets.add(TargetInfo(
    name: "fetch",
    kind: bkBin,
    main: "tools/fetch.nim",
    output: "demo_fetch",
    source: "tools",
    paths: @["src"]))

  let ctx = initBuildContext(cfg, "dev", getTempDir(), false)
  let plan = resolveTargetPlan(ctx, 0)
  doAssert plan.outputName == "demo_fetch"
  doAssert plan.sourceDir == "tools"
  doAssert plan.compilerFlags.anyIt(it.endsWith("/src") or it.endsWith("\\src"))

block api_docs_are_discovered_and_indexed:
  let tmp = getTempDir() / "bau-test-api-docs"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
kind = "lib"
source = "src"
main = "src/demo.nim"

[docs]
exclude = ["src/demo/private/**"]
""")
  write(tmp / "src" / "demo.nim", """
## Demo package.

import demo/[api, extra]
export api
export extra
""")
  write(tmp / "src" / "demo" / "api.nim", """
## Public API.

proc answer*(): int =
  ## Returns the answer.
  42
""")
  write(tmp / "src" / "demo" / "extra.nim", """
## Extra public API.

const extraValue* = 7 ## Additional exported value.
""")
  write(tmp / "src" / "demo" / "private" / "secret.nim", """
## Private implementation details.

const secret* = 1
""")

  var opts = defaultOperationOptions()
  opts.docSkipExamples = true
  let op = docOperation(tmp, opts)
  doAssert op.ok
  doAssert fileExists(tmp / "docs" / "demo.html")
  doAssert fileExists(tmp / "docs" / "demo" / "api.html")
  doAssert fileExists(tmp / "docs" / "demo" / "extra.html")
  doAssert fileExists(tmp / "docs" / "theindex.html")
  doAssert not fileExists(tmp / "docs" / "demo" / "private" / "secret.html")
  doAssert fileExists(tmp / "docs" / ".bau-docs-manifest")

  var modules: seq[string]
  for module in op.json["modules"].getElems():
    modules.add(module["file"].getStr())
  doAssert "src/demo.nim" in modules
  doAssert "src/demo/api.nim" in modules
  doAssert "src/demo/extra.nim" in modules
  doAssert "src/demo/private/secret.nim" notin modules
  doAssert op.json["diagnostics"].len == 0

block explain_operation_reports_fresh_and_cached_fingerprints:
  let tmp = getTempDir() / "bau-test-explain-operation"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"
version = "0.1.0"

[build]
main = "src/demo.nim"
output = "demo"
""")
  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")

  var opts = defaultOperationOptions()
  opts.profile = "dev"
  let missing = explainOperation(tmp, opts)
  doAssert not missing.json["cached"].getBool()
  doAssert missing.json.hasKey("freshFingerprint")
  doAssert missing.json["sourceFiles"].getElems().anyIt(
    it.getStr().endsWith("src/demo.nim"))

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  let ctx = initBuildContext(cfg, "dev", tmp, false, FeatureSelection())
  let plan = resolveTargetPlan(ctx, -1)
  let inputs = initFingerprintInputs(plan.sourceFiles, plan.compilerFlags,
    plan.profile, collectFingerprintConfigInputs(tmp),
    collectFingerprintEnvInputs())
  saveFingerprint(tmp / BuildDirName / FingerprintDirName, plan.outputName,
    "main", computeFingerprint(inputs))
  write(plan.binaryPath, "binary\n")

  let cached = explainOperation(tmp, opts)
  doAssert cached.json["cached"].getBool()
  doAssert cached.json["comparison"]["source"]["unchanged"].getBool()
  doAssert cached.json["wouldSkip"].getBool()

  write(tmp / "src" / "demo.nim", "echo \"changed\"\n")
  let changed = explainOperation(tmp, opts)
  doAssert not changed.json["comparison"]["source"]["unchanged"].getBool()
  doAssert changed.json["changed"].getBool()

block dependency_tree_and_status_use_lock_graph:
  let tmp = getTempDir() / "bau-test-dependency-inspection"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[dependencies]
root = ">=1.0"
""")
  write(tmp / "deps" / "root" / "root.nimble", """
version = "1.2.0"
requires "child >=0.1"
""")
  write(tmp / "deps" / "root" / "src" / "root.nim", "const root* = 1\n")
  write(tmp / "deps" / "child" / "child.nimble", """
version = "0.2.0"
""")
  write(tmp / "deps" / "child" / "src" / "child.nim", "const child* = 1\n")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  writeLockFile(generateLockFile(cfg, tmp), tmp / LockFileName)

  let tree = dependencyTreeJson(cfg, tmp)
  doAssert tree["dependencies"].len == 1
  let root = tree["dependencies"][0]
  doAssert root["name"].getStr() == "root"
  doAssert root["locked"]["version"].getStr() == "1.2.0"
  doAssert root["locked"]["dependencies"].len == 1
  let child = root["locked"]["dependencies"][0]
  doAssert child["name"].getStr() == "child"
  doAssert child["package"]["version"].getStr() == "0.2.0"

  let text = dependencyTreeText(cfg, tmp)
  doAssert "root >=1.0 -> 1.2.0" in text
  doAssert "child >=0.1 -> 0.2.0" in text

  let status = dependencyStatusJson(cfg, tmp)
  doAssert status["lockOk"].getBool()
  doAssert status["dependencies"][0]["status"].getStr() == "ok"

  var staleCfg = cfg
  staleCfg.deps["extra"] = DepInfo(version: some(">=1.0"))
  let stale = dependencyStatusJson(staleCfg, tmp)
  doAssert not stale["lockOk"].getBool()
  doAssert stale["diagnostics"].getElems().anyIt(
    it["kind"].getStr() == "stale-requirements")

  writeFile(tmp / LockFileName, "version = 1\n")
  let invalid = dependencyStatusJson(cfg, tmp)
  doAssert invalid["dependencies"][0]["status"].getStr() == "invalid-lock"
