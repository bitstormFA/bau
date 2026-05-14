import std/[json, os, strutils]
import bau/[config, installer, ops]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block install_config_parses_and_defaults_to_bau_bin:
  let cfg = parseBauConfig("""
[package]
name = "demo"

[install]
dir = "bin"
""")
  doAssert cfg.install.dir == "bin"

  let defaultDir = defaultInstallDir().replace("\\", "/")
  doAssert defaultDir.endsWith(".bau/bin")
  doAssert ".nimble/bin" notin defaultDir

block shell_init_adds_bash_path_idempotently:
  let tmp = getTempDir() / "bau-test-shell-init-bash"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  let first = initShellPath("bash", "", tmp)
  doAssert first.changed
  doAssert first.shell == "bash"
  doAssert first.configPath == absolutePath(tmp) / ".bashrc"
  doAssert dirExists(absolutePath(tmp) / ".bau" / "bin")

  let content = readFile(first.configPath)
  doAssert "case \":$PATH:\"" in content
  doAssert "$HOME/.bau/bin" in content

  let second = initShellPath("bash", "", tmp)
  doAssert not second.changed
  doAssert second.alreadyConfigured
  doAssert readFile(first.configPath) == content

block shell_init_persists_when_bau_bin_is_already_on_path:
  let tmp = getTempDir() / "bau-test-shell-init-path"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  let binDir = absolutePath(tmp) / ".bau" / "bin"
  let result = initShellPath("zsh", binDir, tmp)
  doAssert result.changed
  doAssert result.alreadyInPath
  doAssert fileExists(absolutePath(tmp) / ".zshrc")
  doAssert "$HOME/.bau/bin" in readFile(result.configPath)

block shell_init_uses_fish_config:
  let tmp = getTempDir() / "bau-test-shell-init-fish"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  let result = initShellPath("fish", "", tmp)
  doAssert result.changed
  doAssert result.configPath == absolutePath(tmp) / ".config" / "fish" /
    "config.fish"
  let content = readFile(result.configPath)
  doAssert "contains -- $HOME/.bau/bin $PATH" in content
  doAssert "fish_add_path $HOME/.bau/bin" in content

block install_dry_run_reports_all_binary_targets:
  let tmp = getTempDir() / "bau-test-install-dry-run"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[package]
name = "demo"

[build]
kind = "bin"
main = "src/demo.nim"
output = "demo"

[[targets]]
name = "worker"
kind = "bin"
main = "src/worker.nim"

[install]
dir = "installed"
""")
  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")
  write(tmp / "src" / "worker.nim", "echo \"worker\"\n")

  var opts = defaultOperationOptions()
  opts.dryRun = true
  opts.allTargets = true
  let op = installOperation(tmp, opts)
  doAssert op.ok
  doAssert op.json["status"].getStr() == "planned"
  doAssert op.json["targets"].len == 2
  doAssert op.json["targets"][0]["destination"].getStr().endsWith(
    "installed/demo")
  doAssert op.json["targets"][1]["destination"].getStr().endsWith(
    "installed/worker")
  doAssert not fileExists(tmp / "installed" / "demo")

block install_update_and_remove_binary:
  let tmp = getTempDir() / "bau-test-install-operation"
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
kind = "bin"
source = "src"
main = "src/demo.nim"
output = "demo"

[install]
dir = "installed"
""")
  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")

  var opts = defaultOperationOptions()
  let installed = installOperation(tmp, opts)
  doAssert installed.ok
  doAssert installed.json["status"].getStr() == "installed"
  doAssert fileExists(tmp / "installed" / "demo")

  let duplicate = installOperation(tmp, opts)
  doAssert not duplicate.ok
  doAssert "already installed" in duplicate.output

  opts.installAction = "update"
  let updated = installOperation(tmp, opts)
  doAssert updated.ok
  doAssert updated.json["status"].getStr() == "updated"
  doAssert fileExists(tmp / "installed" / "demo")

  opts.installAction = "remove"
  let removed = installOperation(tmp, opts)
  doAssert removed.ok
  doAssert removed.json["status"].getStr() == "removed"
  doAssert not fileExists(tmp / "installed" / "demo")

  let missing = installOperation(tmp, opts)
  doAssert not missing.ok
  doAssert "not installed" in missing.output
