## Shared filesystem, command, hashing, and terminal helpers.

import std/[os, strutils, osproc, streams, terminal]
import bau/digest

const
  BauVersion* = "0.3.2" ## Version reported by the Bau CLI.
  ConfigFileName* = "bau.toml" ## Primary project configuration filename.
  LocalConfigFileName* = "bau.local.toml" ## Optional local override filename.
  GlobalConfigDir* = "bau" ## User config directory name below the platform config root.
  BuildDirName* = "build" ## Default build artifact directory.
  FingerprintDirName* = ".bau/fingerprints" ## Directory for incremental build fingerprints.

var
  quietOutput = false
  colorMode = "auto"

proc setOutputOptions*(quiet: bool; color: string) =
  ## Configure process-wide terminal output behavior.
  ##
  ## `color` accepts `auto`, `always`, or `never`; unknown values keep the
  ## previous color setting.
  quietOutput = quiet
  if color in ["auto", "always", "never"]:
    colorMode = color

proc outputUsesColor(): bool =
  colorMode == "always" or (colorMode == "auto" and isatty(stdout))

proc currentColorMode*(): string =
  ## Return the active color mode used by terminal helpers.
  colorMode

proc homeDir*(): string =
  ## Return the current user's home directory.
  getHomeDir()

proc globalConfigPath*(): string =
  ## Return the path to the user-level Bau config file.
  getConfigDir() / GlobalConfigDir / "config.toml"

proc globalTasksPath*(): string =
  ## Return the path to the user-level Bau tasks file.
  getConfigDir() / GlobalConfigDir / "tasks.toml"

proc findProjectRoot*(startDir: string = getCurrentDir()): string =
  ## Walk upward from `startDir` until a `bau.toml` file is found.
  ##
  ## Raises `IOError` when no project root exists in the directory ancestry.
  var dir = absolutePath(startDir)
  while dir.len > 0:
    if fileExists(dir / ConfigFileName):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "no " & ConfigFileName & " found in " & startDir & " or any parent")

proc findConfig*(startDir: string = getCurrentDir()): string =
  ## Return the nearest `bau.toml` path, or an empty string when absent.
  try:
    let root = findProjectRoot(startDir)
    result = root / ConfigFileName
  except IOError:
    result = ""

proc readFileChecked*(path: string): string =
  ## Read a file, raising an `IOError` that includes the requested path.
  try:
    result = readFile(path)
  except IOError:
    raise newException(IOError, "cannot read file: " & path)

proc saveFile*(path: string; content: string) =
  ## Write `content` to `path`, creating parent directories first.
  createDir(parentDir(path))
  writeFile(path, content)

proc hashStr*(data: string): string =
  ## Return Bau's prefixed SHA-256 digest for a string.
  digestStr(data)

proc hashFile*(path: string): string =
  ## Return Bau's prefixed SHA-256 digest for a file's contents.
  hashStr(readFileChecked(path))

proc platformTriple*(): string =
  ## Return the host platform as `os-cpu`.
  hostOS & "-" & hostCPU

proc nimVersion*(): string =
  ## Return the Nim version baked into the compiler that built Bau.
  const NimMajor {.intdefine.}: int = 0
  const NimMinor {.intdefine.}: int = 0
  const NimPatch {.intdefine.}: int = 0
  $NimMajor & "." & $NimMinor & "." & $NimPatch

proc detectNimCompiler*(): string =
  ## Find the `nim` executable on `PATH`, raising if it is unavailable.
  result = findExe("nim")
  if result.len == 0:
    raise newException(IOError, "nim compiler not found in PATH")

proc detectAtlas*(): string =
  ## Find the `atlas` executable on `PATH`, raising if it is unavailable.
  result = findExe("atlas")
  if result.len == 0:
    raise newException(IOError, "atlas not found in PATH")

proc runCmd*(cmd: string; args: openArray[string] = [];
    cwd: string = ""): tuple[exitCode: int; output: string] =
  ## Run a command and capture combined stdout and stderr.
  let process = startProcess(cmd, args = @args, options = {poStdErrToStdOut,
      poUsePath}, workingDir = cwd)
  var output = ""
  var line = ""
  while true:
    if not process.outputStream.readLine(line):
      break
    output.add(line & "\n")
  let exitCode = process.waitForExit()
  result = (exitCode: exitCode, output: output)

proc runCmdChecked*(cmd: string; args: openArray[string] = [];
    cwd: string = ""): string =
  ## Run a command and return captured output, raising on nonzero exit.
  let (exitCode, output) = runCmd(cmd, args, cwd)
  if exitCode != 0:
    raise newException(IOError, cmd & " failed with exit code " & $exitCode &
        ":\n" & output)
  result = output

proc runCmdLive*(cmd: string; args: openArray[string] = []; cwd: string = "") =
  ## Run a command attached to the parent terminal, raising on nonzero exit.
  let process = startProcess(cmd, args = @args, options = {poParentStreams,
      poUsePath}, workingDir = cwd)
  let exitCode = process.waitForExit()
  close(process)
  if exitCode != 0:
    raise newException(IOError, cmd & " failed with exit code " & $exitCode)

proc info*(msg: string) =
  ## Print an informational message unless quiet output is enabled.
  if quietOutput:
    return
  if outputUsesColor():
    stdout.styledWrite(fgCyan, "==> ", resetStyle, msg, "\n")
  else:
    echo "==> ", msg

proc warn*(msg: string) =
  ## Print a warning message.
  if outputUsesColor():
    stdout.styledWrite(fgYellow, "WARN ", resetStyle, msg, "\n")
  else:
    echo "WARN ", msg

proc error*(msg: string) =
  ## Print an error message.
  if outputUsesColor():
    stdout.styledWrite(fgRed, "ERROR ", resetStyle, msg, "\n")
  else:
    echo "ERROR ", msg

proc success*(msg: string) =
  ## Print a success message unless quiet output is enabled.
  if quietOutput:
    return
  if outputUsesColor():
    stdout.styledWrite(fgGreen, "OK   ", resetStyle, msg, "\n")
  else:
    echo "OK   ", msg

proc toTomlString*(s: string): string =
  ## Quote a string for TOML output, using multiline syntax when needed.
  if s.contains('\n') or s.contains('"') or s.contains('\\'):
    var escaped = s.replace("\\", "\\\\").replace("\"", "\\\"")
    result = "\"\"\"\n" & escaped & "\"\"\""
  else:
    result = "\"" & s & "\""
