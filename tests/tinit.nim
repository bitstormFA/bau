import std/os
import bau/[command, config, init, ops]

block parse_init_positional_name_and_kind:
  let opts = parseCliOptions(@["init", "sample", "--lib"])
  doAssert opts.command == cmdInit
  doAssert opts.initInfo.name == "sample"
  doAssert opts.initInfo.kind == "lib"
  doAssert opts.args.len == 0

block parse_init_metadata_flags:
  let opts = parseCliOptions(@[
    "init",
    "--name", "toolbox",
    "--bin",
    "--version", "1.2.3",
    "--description", "Useful tools",
    "--license", "Apache-2.0",
    "--edition", "2026"
  ])
  doAssert opts.command == cmdInit
  doAssert opts.initInfo.name == "toolbox"
  doAssert opts.initInfo.kind == "bin"
  doAssert opts.initInfo.version == "1.2.3"
  doAssert opts.initInfo.description == "Useful tools"
  doAssert opts.initInfo.license == "Apache-2.0"
  doAssert opts.initInfo.edition == "2026"

block parse_new_keeps_path_and_kind:
  let opts = parseCliOptions(@["new", "pkgdir", "--lib"])
  doAssert opts.command == cmdNew
  doAssert opts.args == @["pkgdir"]
  doAssert opts.initInfo.kind == "lib"

block parse_new_workflow_commands:
  let defaults = defaultOptions()
  doAssert defaults.jobs > 0

  let graph = parseCliOptions(@["graph", "--format", "json"])
  doAssert graph.command == cmdGraph
  doAssert graph.format == "json"

  let task = parseCliOptions(@["task", "docs", "--dry-run", "--keep-going"])
  doAssert task.command == cmdTask
  doAssert task.taskName == "docs"
  doAssert task.dryRun
  doAssert task.keepGoing

  let test = parseCliOptions(@["test", "config", "--changed", "--", "--seed", "1"])
  doAssert test.command == cmdTest
  doAssert test.args == @["config"]
  doAssert test.changed
  doAssert test.passthroughArgs == @["--seed", "1"]

  let shorthand = parseCliOptions(@["server", "--profile", "release"])
  doAssert shorthand.command == cmdBuild
  doAssert shorthand.args == @["server"]
  doAssert shorthand.profile == "release"

  let runTarget = parseCliOptions(@["run", "server", "--", "--port", "8080"])
  doAssert runTarget.command == cmdRun
  doAssert runTarget.args == @["server"]
  doAssert runTarget.passthroughArgs == @["--port", "8080"]

  let runDefault = parseCliOptions(@["run", "--", "--help"])
  doAssert runDefault.command == cmdRun
  doAssert runDefault.args.len == 0
  doAssert runDefault.passthroughArgs == @["--help"]

  let deps = parseCliOptions(@["deps", "sync", "--locked", "--offline"])
  doAssert deps.command == cmdDeps
  doAssert deps.args == @["sync"]
  doAssert deps.locked
  doAssert deps.offline

  let affected = parseCliOptions(@[
    "affected", "test", "--since", "origin/main", "--features", "cli,sqlite"
  ])
  doAssert affected.command == cmdAffected
  doAssert affected.args == @["test"]
  doAssert affected.since == "origin/main"
  doAssert affected.features == @["cli", "sqlite"]

  let cache = parseCliOptions(@["cache", "clean"])
  doAssert cache.command == cmdCache
  doAssert cache.args == @["clean"]

  let doctor = parseCliOptions(@["doctor"])
  doAssert doctor.command == cmdDoctor

  let convert = parseCliOptions(@["convert", "demo.nimble", "--dry-run", "--force"])
  doAssert convert.command == cmdConvert
  doAssert convert.args == @["demo.nimble"]
  doAssert convert.dryRun
  doAssert convert.force

  let docs = parseCliOptions(@[
    "doc",
    "--out-dir", "site/api",
    "--entry", "src/manual.nim",
    "--skip-examples",
    "--include-private",
    "--no-index"
  ])
  doAssert docs.command == cmdDoc
  doAssert docs.docOutDir == "site/api"
  doAssert docs.docEntrypoints == @["src/manual.nim"]
  doAssert docs.docSkipExamples
  doAssert docs.docIncludePrivate
  doAssert docs.docNoIndex

  let frozen = parseCliOptions(@["deps", "sync", "--frozen"])
  doAssert frozen.command == cmdDeps
  doAssert frozen.locked
  doAssert frozen.offline

  let install = parseCliOptions(@[
    "install", "cli", "--profile", "release", "--install-dir", "bin"
  ])
  doAssert install.command == cmdInstall
  doAssert install.args == @["cli"]
  doAssert install.profile == "release"
  doAssert install.installDir == "bin"

  let installUpdate = parseCliOptions(@["install", "--update", "--all-targets"])
  doAssert installUpdate.command == cmdInstall
  doAssert installUpdate.update
  doAssert installUpdate.allTargets

  let uninstall = parseCliOptions(@["uninstall", "--dir", "bin"])
  doAssert uninstall.command == cmdUninstall
  doAssert uninstall.installDir == "bin"

  let update = parseCliOptions(@["update", "cli"])
  doAssert update.command == cmdUpdate
  doAssert update.args == @["cli"]

  let shellInit = parseCliOptions(@["shell-init", "fish", "--json"])
  doAssert shellInit.command == cmdShellInit
  doAssert shellInit.args == @["fish"]
  doAssert shellInit.json

  let bump = parseCliOptions(@["bump", "--patch", "--dry-run"])
  doAssert bump.command == cmdBump
  doAssert bump.args == @["--patch"]
  doAssert bump.dryRun

  let bumpAlias = parseCliOptions(@["version-bump", "minor"])
  doAssert bumpAlias.command == cmdBump
  doAssert bumpAlias.args == @["minor"]

block dependency_option_parser_is_strict:
  var op = defaultOperationOptions()
  op.applyDependencyArgs(@[
    "--git", "https://example.com/pkg.git",
    "--tag", "v1.0.0",
    "--optional"
  ])
  doAssert op.depGit == "https://example.com/pkg.git"
  doAssert op.depTag == "v1.0.0"
  doAssert op.depOptional

  var raised = false
  try:
    var bad = defaultOperationOptions()
    bad.applyDependencyArgs(@["--git"])
  except ValueError:
    raised = true
  doAssert raised

  raised = false
  try:
    var bad = defaultOperationOptions()
    bad.applyDependencyArgs(@["--unknown"])
  except ValueError:
    raised = true
  doAssert raised

  raised = false
  try:
    var bad = defaultOperationOptions()
    bad.applyDependencyArgs(@["--path", "../pkg", "--rev", "abc123"])
  except ValueError:
    raised = true
  doAssert raised

block init_project_uses_metadata:
  let tmpDir = getTempDir() / "bau-test-init-project"
  if dirExists(tmpDir):
    removeDir(tmpDir)
  defer:
    if dirExists(tmpDir):
      removeDir(tmpDir)

  let info = ProjectInitInfo(
    name: "samplelib",
    kind: "lib",
    version: "1.2.3",
    description: "Sample library",
    license: "Apache-2.0",
    edition: "2026")

  initProject(tmpDir, info)

  let cfg = parseBauConfigFile(tmpDir / "bau.toml")
  doAssert cfg.package.name == "samplelib"
  doAssert cfg.package.version == "1.2.3"
  doAssert cfg.package.description == "Sample library"
  doAssert cfg.package.license == "Apache-2.0"
  doAssert cfg.package.edition == "2026"
  doAssert cfg.build.kind == bkLib
  doAssert cfg.build.main == "src/samplelib.nim"
  doAssert cfg.docs.entrypoints == @["src/samplelib.nim"]
  doAssert cfg.docs.outDir == "docs"
  doAssert fileExists(tmpDir / "src" / "samplelib.nim")
