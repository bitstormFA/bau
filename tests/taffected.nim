import std/[os, osproc]
import bau/[affected, config, nimscan]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc exec(cmd: string; cwd: string) =
  let exitCode = execShellCmd("cd " & quoteShell(cwd) & " && " & cmd)
  doAssert exitCode == 0

block affected_tracks_grouped_imports_and_includes:
  let tmp = getTempDir() / "bau-test-affected"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/main.nim"
output = "demo"
""")
  write(tmp / "src" / "main.nim", """
import std/[os, strutils], util
include generated
when isMainModule:
  discard utilValue()
""")
  write(tmp / "src" / "util.nim", """
proc utilValue*(): int = 1
""")
  write(tmp / "src" / "generated.nim", """
const generatedValue* = 1
""")
  write(tmp / "tests" / "tutil.nim", """
import util
doAssert utilValue() == 1
""")

  exec("git init -q", tmp)
  exec("git add .", tmp)
  exec("git -c user.email=a@example.com -c user.name=a commit -q -m init", tmp)
  write(tmp / "src" / "util.nim", """
proc utilValue*(): int = 2
""")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  let report = computeAffected(cfg, tmp, "HEAD")
  doAssert "src/util.nim" in report.changedFiles
  doAssert "src/main.nim" in report.sourceFiles
  doAssert "tests/tutil.nim" in report.sourceFiles
  doAssert "demo" in report.targets
  doAssert "tests/tutil.nim" in report.tests

block affected_tracks_config_changes_and_task_globs:
  let tmp = getTempDir() / "bau-test-affected-config"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/main.nim"
output = "demo"

[[targets]]
name = "worker"
kind = "bin"
main = "src/worker.nim"

[[tasks]]
name = "generate"
cmd = "echo generate"
inputs = ["schema/**/*.json"]

[[tasks]]
name = "docs"
cmd = "echo docs"
inputs = ["docs/*.md"]
""")
  write(tmp / "src" / "main.nim", "echo \"demo\"\n")
  write(tmp / "src" / "worker.nim", "echo \"worker\"\n")
  write(tmp / "tests" / "tdemo.nim", "doAssert true\n")
  write(tmp / "tests" / "tworker.nim", "doAssert true\n")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  let configReport = computeAffectedFromChanges(cfg, tmp, @["bau.toml"])
  doAssert configReport.targets == @["demo", "worker"]
  doAssert configReport.tests == @["tests/tdemo.nim", "tests/tworker.nim"]
  doAssert configReport.tasks == @["docs", "generate"]

  let globReport = computeAffectedFromChanges(cfg, tmp,
    @["schema/nested/api.json"])
  doAssert globReport.tasks == @["generate"]
  doAssert globReport.targets.len == 0

block scanner_handles_multiline_aliases_and_duplicate_names:
  let tmp = getTempDir() / "bau-test-nimscan"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/app/main.nim"
output = "demo"
""")
  write(tmp / "src" / "app" / "main.nim", """
import pkg/[
  util,
  extra
]
from app/local import localValue
include app/generated
when isMainModule:
  discard packageUtil()
""")
  write(tmp / "src" / "pkg" / "util.nim", "proc packageUtil*(): int = 1\n")
  write(tmp / "src" / "pkg" / "extra.nim", "const extra* = 1\n")
  write(tmp / "src" / "app" / "local.nim", "proc localValue*(): int = 1\n")
  write(tmp / "src" / "app" / "generated.nim", "const generated* = 1\n")
  write(tmp / "src" / "other" / "util.nim", "const otherUtil* = 1\n")
  write(tmp / "tests" / "tmain.nim", "import app/main\n")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  let scanned = scanNimModule(tmp, "src/app/main.nim")
  doAssert "pkg/util" in scanned.imports
  doAssert "pkg/extra" in scanned.imports
  doAssert "app/local" in scanned.imports
  doAssert "app/generated" in scanned.includes
  doAssert scanned.isMainModule

  let report = computeAffectedFromChanges(cfg, tmp, @["src/pkg/util.nim"])
  doAssert "src/app/main.nim" in report.sourceFiles
  doAssert "src/other/util.nim" notin report.sourceFiles

block compiler_dependency_edges_are_resolved_and_cleaned:
  let tmp = getTempDir() / "bau-test-nimscan-compiler"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
main = "src/app/main.nim"
output = "demo"
""")
  write(tmp / "src" / "app" / "main.nim", """
import lib/util
when isMainModule:
  discard packageUtil()
""")
  write(tmp / "src" / "lib" / "util.nim", "proc packageUtil*(): int = 1\n")

  let cfg = parseBauConfigFile(tmp / "bau.toml")

  let compilerEdges = compilerDependencyEdges(tmp, cfg)
  if compilerEdges.len > 0:
    var sawCompilerEdge = false
    for edge in compilerEdges:
      if edge.imported in ["lib/util", "../lib/util"] and
          edge.importer in ["main", "app/main"]:
        sawCompilerEdge = true
    doAssert sawCompilerEdge
  let report = computeAffectedFromChanges(cfg, tmp, @["src/lib/util.nim"])
  doAssert "src/app/main.nim" in report.sourceFiles
  doAssert not fileExists(tmp / "src" / "app" / "main.dot")
  doAssert not fileExists(tmp / "src" / "app" / "main.png")
