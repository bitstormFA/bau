## Creates new Bau project skeletons.

import std/[os, strutils]
import bau/util

type
  ProjectInitInfo* = object ## User-provided metadata for project scaffolding.
    name*: string ## Package and main module name.
    kind*: string ## Project kind, normalized to `bin` or `lib`.
    version*: string ## Initial package version.
    description*: string ## Initial package description.
    license*: string ## Initial package license.
    edition*: string ## Bau configuration edition to write.

const
  MainNimTemplate = """import std/strformat

proc main() =
  echo &"Hello from $1!"

when isMainModule:
  main()
"""

  LibNimTemplate = """proc hello*(): string =
  "Hello from $1!"
"""

  TestBasicTemplate = """block name_check:
  doAssert true
"""

  TestConfigNims = """switch("path", "$projectdir/../src")
"""

  GitIgnoreTemplate = """build/
*.exe
*.out
nimcache/
"""

proc defaultProjectDescription*(kind: string): string =
  ## Return the default package description for a normalized project kind.
  if kind == "lib":
    "A Nim library"
  else:
    "A Nim project"

proc normalizeProjectKind*(kind: string): string =
  ## Normalize user-facing project-kind aliases to `bin` or `lib`.
  let value = kind.toLowerAscii()
  case value
  of "", "bin", "binary", "exe":
    "bin"
  of "lib", "library":
    "lib"
  else:
    raise newException(ValueError, "unknown project kind: " & kind)

proc initProjectInfo*(name: string; kind: string = "bin"): ProjectInitInfo =
  ## Build default initialization metadata from a name and project kind.
  result.name = if name.len > 0: name else: "main"
  result.kind = normalizeProjectKind(kind)
  result.version = "0.1.0"
  result.description = defaultProjectDescription(result.kind)
  result.license = "MIT"
  result.edition = "2026"

proc promptValue(label: string; defaultValue: string): string =
  stdout.write(label & " [" & defaultValue & "]: ")
  flushFile(stdout)
  try:
    result = stdin.readLine().strip()
  except EOFError:
    result = ""
  if result.len == 0:
    result = defaultValue

proc promptProjectKind(defaultKind: string): string =
  while true:
    let value = promptValue("Project kind (bin/lib)", defaultKind)
    try:
      return normalizeProjectKind(value)
    except ValueError:
      warn("please enter 'bin' or 'lib'")

proc completeProjectInitInfo*(partial: ProjectInitInfo;
    defaultName: string): ProjectInitInfo =
  ## Fill missing initialization metadata by prompting on stdin.
  result = partial
  if result.name.len == 0:
    result.name = promptValue("Project name", defaultName)
  if result.kind.len == 0:
    result.kind = promptProjectKind("bin")
  else:
    result.kind = normalizeProjectKind(result.kind)
  if result.version.len == 0:
    result.version = promptValue("Version", "0.1.0")
  if result.description.len == 0:
    result.description = promptValue("Description",
      defaultProjectDescription(result.kind))
  if result.license.len == 0:
    result.license = promptValue("License", "MIT")
  if result.edition.len == 0:
    result.edition = promptValue("Edition", "2026")

proc withProjectDefaults(info: ProjectInitInfo): ProjectInitInfo =
  let kind = normalizeProjectKind(info.kind)
  result = ProjectInitInfo(
    name: if info.name.len > 0: info.name else: "main",
    kind: kind,
    version: if info.version.len > 0: info.version else: "0.1.0",
    description: if info.description.len > 0: info.description else:
      defaultProjectDescription(kind),
    license: if info.license.len > 0: info.license else: "MIT",
    edition: if info.edition.len > 0: info.edition else: "2026")

proc makeBauToml(info: ProjectInitInfo): string =
  result = "[package]\n"
  result.add("name = " & toTomlString(info.name) & "\n")
  result.add("version = " & toTomlString(info.version) & "\n")
  result.add("description = " & toTomlString(info.description) & "\n")
  result.add("license = " & toTomlString(info.license) & "\n")
  result.add("edition = " & toTomlString(info.edition) & "\n\n")

  result.add("[build]\n")
  result.add("kind = " & toTomlString(info.kind) & "\n")
  result.add("source = \"src\"\n")
  result.add("main = " & toTomlString("src/" & info.name & ".nim") & "\n")
  if info.kind == "bin":
    result.add("output = " & toTomlString(info.name) & "\n")
  result.add("\n")

  result.add("[profile.dev]\n")
  result.add("flags = [\"--debugInfo:on\"]\n")
  result.add("gc = \"orc\"\n\n")

  result.add("[profile.release]\n")
  result.add("flags = [\"--opt:speed\"]\n")
  result.add("gc = \"orc\"\n\n")

  result.add("[docs]\n")
  result.add("entrypoints = [" & toTomlString("src/" & info.name & ".nim") &
    "]\n")
  result.add("outDir = \"docs\"\n")

proc initProject*(dir: string; info: ProjectInitInfo; force: bool = false) =
  ## Create a Bau project skeleton in `dir`.
  ##
  ## Existing `bau.toml` files are preserved unless `force` is true.
  let project = withProjectDefaults(info)
  let projectDir = absolutePath(dir)

  if not force and fileExists(projectDir / ConfigFileName):
    raise newException(IOError, "project already exists at " & projectDir &
      " (use --force to overwrite)")

  createDir(projectDir)

  let srcDir = projectDir / "src"
  createDir(srcDir)

  let testsDir = projectDir / "tests"
  createDir(testsDir)

  let scriptsDir = projectDir / "scripts"
  createDir(scriptsDir)

  let mainFile = project.name & ".nim"

  saveFile(projectDir / ConfigFileName, makeBauToml(project))
  if project.kind == "lib":
    saveFile(srcDir / mainFile, LibNimTemplate % [project.name])
  else:
    saveFile(srcDir / mainFile, MainNimTemplate % [project.name])

  saveFile(testsDir / "tbasic.nim", TestBasicTemplate)
  saveFile(testsDir / "config.nims", TestConfigNims)
  saveFile(projectDir / ".gitignore", GitIgnoreTemplate)

  success("initialized " & project.kind & " project '" & project.name &
    "' at " & projectDir)

proc initProject*(dir: string; name: string; kind: string = "bin";
    force: bool = false) =
  ## Create a Bau project skeleton from simple name and kind arguments.
  initProject(dir, initProjectInfo(name, kind), force)

proc initNew*(path: string; info: ProjectInitInfo; force: bool = false) =
  ## Create a new project, creating the parent directory first when needed.
  let parentDir = parentDir(absolutePath(path))
  createDir(parentDir)
  initProject(path, info, force)

proc initNew*(path: string; name: string; kind: string = "bin";
    force: bool = false) =
  ## Create a new project from simple name and kind arguments.
  initNew(path, initProjectInfo(name, kind), force)
