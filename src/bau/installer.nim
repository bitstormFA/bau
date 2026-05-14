## Installs, updates, and removes Bau-built binaries.

import std/[os, strutils]
import bau/[build, config, features, util]

when defined(windows):
  const EnvPathSep = ';'
else:
  const EnvPathSep = ':'

type
  InstallAction* = enum ## Binary installation operation to perform.
    iaInstall = "install" ## Install a binary that is not already present.
    iaUpdate = "update" ## Replace an existing installed binary.
    iaRemove = "remove" ## Remove an installed binary.

  InstallResult* = object ## Outcome for one target handled by install commands.
    action*: InstallAction ## Operation that was requested.
    target*: string ## Target output name.
    profile*: string ## Profile used to build the target.
    source*: string ## Built binary path.
    destination*: string ## Final installed binary path.
    installDir*: string ## Directory selected for installation.
    changed*: bool ## True when the filesystem was modified.
    dryRun*: bool ## True when the command only planned the operation.

  ShellInitResult* = object ## Outcome from configuring a shell startup file.
    shell*: string ## Shell that was configured.
    configPath*: string ## Startup file selected for the shell.
    binDir*: string ## Bau binary directory checked or configured.
    changed*: bool ## True when the startup file was modified.
    alreadyInPath*: bool ## True when the current PATH already contains binDir.
    alreadyConfigured*: bool ## True when the startup file already mentions binDir.

proc defaultInstallDir*(): string =
  ## Return the default binary install directory.
  ##
  ## Bau installs to `~/.bau/bin` unless overridden by CLI or config.
  homeDir() / ".bau" / "bin"

proc resolveInstallDir*(cfg: BauConfig; projectDir,
    overrideDir: string): string =
  ## Resolve the install directory from CLI override, config, or defaults.
  ##
  ## Relative configured paths are interpreted relative to `projectDir`.
  let configured =
    if overrideDir.len > 0:
      overrideDir
    elif cfg.install.dir.len > 0:
      cfg.install.dir
    else:
      ""
  if configured.len == 0:
    return defaultInstallDir()

  let expanded = expandTilde(configured)
  if expanded.isAbsolute:
    absolutePath(expanded)
  else:
    absolutePath(projectDir / expanded)

proc defaultTargetName(cfg: BauConfig): string =
  if cfg.build.output.len > 0:
    cfg.build.output
  else:
    cfg.package.name

proc samePath(a, b: string): bool =
  normalizedPath(absolutePath(a)) == normalizedPath(absolutePath(b))

proc bauBinDir(home: string): string =
  absolutePath(expandTilde(home)) / ".bau" / "bin"

proc normalizeShellName(selectedShell: string): string =
  var raw = selectedShell
  if raw.len == 0:
    raw = getEnv("SHELL")
  var name = raw.extractFilename
  while name.len > 0 and name[0] == '-':
    name = name[1..^1]
  if name.len == 0:
    name = "sh"

  case name
  of "bash", "zsh", "fish", "sh":
    name
  of "dash", "ksh":
    "sh"
  else:
    raise newException(ValueError, "unsupported shell for shell-init: " &
      name & " (supported: bash, zsh, fish, sh)")

proc shellInitConfigPath(shell, home: string): string =
  case shell
  of "bash":
    home / ".bashrc"
  of "zsh":
    home / ".zshrc"
  of "fish":
    home / ".config" / "fish" / "config.fish"
  else:
    home / ".profile"

proc normalizedPathEntry(path: string): string =
  normalizedPath(absolutePath(expandTilde(path)))

proc pathContainsDir(pathEnv, dir: string): bool =
  let wanted = normalizedPathEntry(dir)
  for entry in pathEnv.split(EnvPathSep):
    if entry.len > 0 and normalizedPathEntry(entry) == wanted:
      return true

proc shellInitSnippet(shell: string): string =
  case shell
  of "fish":
    "# Bau\ncontains -- $HOME/.bau/bin $PATH; or fish_add_path $HOME/.bau/bin\n"
  else:
    "# Bau\ncase \":$PATH:\" in\n  *\":$HOME/.bau/bin:\"*) ;;\n" &
      "  *) export PATH=\"$HOME/.bau/bin:$PATH\" ;;\nesac\n"

proc startupFileMentionsBauBin(content: string): bool =
  ".bau/bin" in content or ".bau\\bin" in content

proc initShellPath*(selectedShell = ""; pathEnv = getEnv("PATH");
    home = homeDir()): ShellInitResult =
  ## Ensure the selected shell starts with `~/.bau/bin` on `PATH`.
  let shell = normalizeShellName(selectedShell)
  let expandedHome = absolutePath(expandTilde(home))
  let binDir = bauBinDir(expandedHome)
  let configPath = shellInitConfigPath(shell, expandedHome)
  result = ShellInitResult(shell: shell, configPath: configPath,
    binDir: binDir)
  result.alreadyInPath = pathContainsDir(pathEnv, binDir)

  let existing = if fileExists(configPath): readFile(configPath) else: ""
  if startupFileMentionsBauBin(existing):
    result.alreadyConfigured = true
    return

  createDir(binDir)
  var content = existing
  if content.len > 0 and not content.endsWith("\n"):
    content.add("\n")
  if content.len > 0:
    content.add("\n")
  content.add(shellInitSnippet(shell))
  saveFile(configPath, content)
  result.changed = true

proc targetIndexes(cfg: BauConfig; targetName: string;
    allTargets: bool): seq[int] =
  if allTargets:
    if cfg.build.kind == bkBin:
      result.add(-1)
    for i, target in cfg.targets:
      if target.kind == bkBin:
        result.add(i)
    if result.len == 0:
      raise newException(ValueError, "no binary targets configured")
    return

  if targetName.len == 0:
    if cfg.build.kind != bkBin:
      raise newException(ValueError, "default target is not a binary")
    return @[-1]

  if targetName == cfg.defaultTargetName:
    if cfg.build.kind != bkBin:
      raise newException(ValueError, "target is not a binary: " & targetName)
    return @[-1]

  let idx = findTargetIndex(cfg, targetName)
  if idx < 0:
    raise newException(ValueError, "target not found: " & targetName)
  if cfg.targets[idx].kind != bkBin:
    raise newException(ValueError, "target is not a binary: " & targetName)
  @[idx]

proc copyBinary(source, destination: string) =
  if samePath(source, destination):
    return

  createDir(parentDir(destination))
  let tempPath = destination & ".bau-tmp-" & $getCurrentProcessId()
  if fileExists(tempPath):
    removeFile(tempPath)
  copyFile(source, tempPath)
  try:
    setFilePermissions(tempPath, getFilePermissions(source))
  except CatchableError:
    discard
  if fileExists(destination):
    removeFile(destination)
  moveFile(tempPath, destination)

proc removeBinary(destination: string; force: bool): bool =
  if fileExists(destination):
    removeFile(destination)
    return true
  if not force:
    raise newException(IOError, "binary is not installed: " & destination)
  false

proc installOne(cfg: BauConfig; idx: int; profile, projectDir,
    installDir: string; action: InstallAction; force, dryRun, verbose: bool;
    featureSelection: FeatureSelection): InstallResult =
  let ctx = initBuildContext(cfg, profile, projectDir, verbose, featureSelection)
  let plan = resolveTargetPlan(ctx, idx)
  if plan.target.kind != bkBin:
    raise newException(ValueError, "target is not a binary: " & plan.outputName)

  let destination = installDir / plan.outputName
  result = InstallResult(
    action: action,
    target: plan.outputName,
    profile: plan.profile,
    source: plan.binaryPath,
    destination: destination,
    installDir: installDir,
    dryRun: dryRun)

  case action
  of iaRemove:
    if not dryRun:
      result.changed = removeBinary(destination, force)
  of iaInstall, iaUpdate:
    let exists = fileExists(destination)
    if action == iaInstall and exists and not force:
      raise newException(IOError, "binary already installed: " & destination &
        " (use bau update or bau install --update)")
    if action == iaUpdate and not exists and not force:
      raise newException(IOError, "binary is not installed: " & destination &
        " (use bau install)")
    if not dryRun:
      let source = buildTarget(cfg, idx, profile, projectDir, verbose,
        featureSelection)
      result.source = source
      copyBinary(source, destination)
      result.changed = true

proc installTargets*(cfg: BauConfig; projectDir, profile, targetName,
    overrideDir: string; action: InstallAction; allTargets, force, dryRun,
    verbose: bool; featureSelection: FeatureSelection): seq[InstallResult] =
  ## Install, update, or remove one or more binary targets.
  ##
  ## Target selection follows `targetName` unless `allTargets` is true.
  let installDir = resolveInstallDir(cfg, projectDir, overrideDir)
  for idx in targetIndexes(cfg, targetName, allTargets):
    result.add(installOne(cfg, idx, profile, projectDir, installDir, action,
      force, dryRun, verbose, featureSelection))
