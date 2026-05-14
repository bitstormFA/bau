import std/[options, os, strutils, tables]
import bau/[config, nimble, packaging]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block convert_static_nimble_project:
  let tmp = getTempDir() / "bau-test-nimble-convert"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  let nimbleData = """
version = "1.2.3"
author = "Ada Lovelace"
""" & "description = \"\"\"\nConverted application\n\"\"\"\n" & """
license = "Apache-2.0"
srcDir = "src"
backend = "cpp"
bin = @["demo", "worker"]
skipDirs = @["bench"]
skipFiles = @["legacy.nim"]
skipExt = @["tmp"]

requires "nim >=2.2",
         "parsetoml >=0.6.0",
         "regex"

when defined(windows):
  requires "winim"

feature "db":
  requires "sqlite >=0.2"

task docs, "Build docs":
  exec "nim doc src/demo.nim"

before build:
  exec "nim r scripts/gen.nims"

after install:
  exec "echo installed"
"""
  write(tmp / "demo.nimble", nimbleData)
  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")
  write(tmp / "src" / "worker.nim", "echo \"worker\"\n")

  let converted = convertNimbleProject(tmp, write = false)
  doAssert not fileExists(tmp / "bau.toml")
  doAssert converted.nimblePath.endsWith("demo.nimble")
  doAssert converted.content.contains("[dependencies]")
  doAssert converted.diagnostics.len == 2
  doAssert converted.diagnostics[0].severity == csInfo
  doAssert converted.diagnostics[1].severity == csWarning

  let cfg = parseBauConfig(converted.content)
  doAssert cfg.package.name == "demo"
  doAssert cfg.package.version == "1.2.3"
  doAssert cfg.package.authors == @["Ada Lovelace"]
  doAssert cfg.package.description.strip() == "Converted application"
  doAssert cfg.package.license == "Apache-2.0"
  doAssert cfg.package.edition == "2026"
  doAssert "bench" in cfg.package.excludeFiles
  doAssert "legacy.nim" in cfg.package.excludeFiles
  doAssert "*.tmp" in cfg.package.excludeFiles

  doAssert cfg.build.kind == bkBin
  doAssert cfg.build.source == "src"
  doAssert cfg.build.main == "src/demo.nim"
  doAssert cfg.build.output == "demo"
  doAssert cfg.build.backend == "cpp"
  doAssert cfg.targets.len == 1
  doAssert cfg.targets[0].name == "worker"
  doAssert cfg.targets[0].main == "src/worker.nim"

  doAssert cfg.toolchain.nim == ">=2.2"
  doAssert cfg.deps["parsetoml"].version == some(">=0.6.0")
  doAssert cfg.deps.hasKey("regex")
  doAssert not cfg.deps.hasKey("winim")
  doAssert cfg.deps["regex"].version.isNone
  doAssert cfg.deps["sqlite"].version == some(">=0.2")
  doAssert cfg.deps["sqlite"].optional
  doAssert cfg.features["db"].enables == @["dep:sqlite"]

  doAssert cfg.scripts.preBuild == some("nim r scripts/gen.nims")
  doAssert cfg.scripts.postInstall == some("echo installed")
  doAssert cfg.tasks.len == 1
  doAssert cfg.tasks[0].name == "docs"
  doAssert cfg.tasks[0].description == "Build docs"
  doAssert cfg.tasks[0].cmd == "nim doc src/demo.nim"
  doAssert cfg.docs.entrypoints == @["src/demo.nim", "src/worker.nim"]

  let nimbleOut = nimbleContent(cfg)
  doAssert "requires \"regex\"" in nimbleOut

block convert_named_bins_and_write_guard:
  let tmp = getTempDir() / "bau-test-nimble-convert-write"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "tools.nimble", """
packageName = "tools"
version = "0.1.0"
namedBin = {"tool": "tools/cli.nim", "helper": "tools/helper"}
""")
  write(tmp / "tools" / "cli.nim", "echo \"tool\"\n")
  write(tmp / "tools" / "helper.nim", "echo \"helper\"\n")

  let written = convertNimbleProject(tmp)
  doAssert written.wrote
  doAssert fileExists(tmp / "bau.toml")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  doAssert cfg.build.kind == bkBin
  doAssert cfg.build.output == "helper"
  doAssert cfg.build.main == "tools/helper.nim"
  doAssert cfg.targets.len == 1
  doAssert cfg.targets[0].name == "tool"
  doAssert cfg.targets[0].main == "tools/cli.nim"

  var raised = false
  try:
    discard convertNimbleProject(tmp)
  except IOError:
    raised = true
  doAssert raised

  let forced = convertNimbleProject(tmp, force = true)
  doAssert forced.wrote

  let parsed = parseNimbleFile(tmp / "tools.nimble")
  doAssert parsed.isSome
  doAssert parsed.get().package.name == "tools"
