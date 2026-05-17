## Updates dependency and patch entries in bau.toml.

import std/[options, os, strutils, tables]
import bau/[config, util]

type
  DependencyEdit* = object ## Editable dependency specification for config updates.
    name*: string     ## Dependency name.
    version*: string  ## Registry version requirement.
    git*: string      ## Git URL.
    tag*: string      ## Git tag.
    branch*: string   ## Git branch.
    rev*: string      ## Exact Git revision.
    path*: string     ## Local path dependency.
    registry*: string ## Named registry source.
    optional*: bool   ## Whether the dependency is feature-gated.

  DependencyEditResult* = object ## Result of editing raw TOML content.
    content*: string             ## Updated TOML content.
    changed*: bool               ## True when content was modified.

  VersionBumpKind* = enum ## SemVer component to increment.
    vbMajor = "major"     ## Increment major and reset minor/patch.
    vbMinor = "minor"     ## Increment minor and reset patch.
    vbPatch = "patch"     ## Increment patch.

  VersionBumpResult* = object ## Result of bumping package version metadata.
    oldVersion*: string       ## Version before the bump.
    newVersion*: string       ## Version after the bump.
    nimblePath*: string       ## Updated `.nimble` file path, when one existed.
    configChanged*: bool      ## True when `bau.toml` content changed.
    nimbleChanged*: bool      ## True when `.nimble` content changed.

proc initDependencyEdit*(name: string): DependencyEdit =
  ## Initialize an edit for a dependency name.
  DependencyEdit(name: name)

proc toDependencyEdit*(name: string; dep: DepInfo): DependencyEdit =
  ## Convert parsed dependency info into an editable dependency record.
  result = initDependencyEdit(name)
  result.git = dep.url.get("")
  result.tag = dep.tag.get("")
  result.branch = dep.branch.get("")
  result.rev = dep.rev.get("")
  result.path = dep.path.get("")
  result.version = dep.version.get("")
  result.registry = dep.registry.get("")
  result.optional = dep.optional

proc addField(parts: var seq[string]; name, value: string) =
  if value.len > 0:
    parts.add(name & " = " & toTomlString(value))

proc dependencyLine*(edit: DependencyEdit): string =
  ## Format a dependency edit as a single TOML assignment line.
  if edit.name.len == 0:
    raise newException(ValueError, "dependency name is required")

  let defaultVersion = if edit.version.len > 0: edit.version else: ">=0.1.0"

  if edit.git.len > 0 or edit.path.len > 0 or edit.registry.len > 0 or
      edit.optional or edit.tag.len > 0 or edit.branch.len > 0 or
      edit.rev.len > 0:
    var parts: seq[string]
    parts.addField("git", edit.git)
    parts.addField("path", edit.path)
    if edit.version.len > 0 or (edit.git.len == 0 and edit.path.len == 0):
      parts.addField("version", defaultVersion)
    parts.addField("registry", edit.registry)
    parts.addField("tag", edit.tag)
    parts.addField("branch", edit.branch)
    parts.addField("rev", edit.rev)
    if edit.optional:
      parts.add("optional = true")
    result = edit.name & " = { " & parts.join(", ") & " }"
  else:
    result = edit.name & " = " & toTomlString(defaultVersion)

proc sectionBounds(content, sectionName: string): tuple[first: int; last: int] =
  let header = "[" & sectionName & "]"
  let first = content.find(header)
  if first < 0:
    return (first: -1, last: -1)
  let next = content.find("\n[", first + header.len)
  let last = if next >= 0: next + 1 else: content.len
  result = (first: first, last: last)

proc startsAssignmentLine(line, key: string): bool =
  let trimmed = line.strip()
  if not trimmed.startsWith(key):
    return false
  if trimmed.len <= key.len:
    return false
  let rest = trimmed[key.len..^1].strip(leading = true, trailing = false)
  rest.startsWith("=")

proc startsDependencyLine(line, depName: string): bool =
  startsAssignmentLine(line, depName)

proc findAssignmentLine(content, key: string; bounds: tuple[first: int;
    last: int]): tuple[found: bool; first: int; last: int] =
  var pos = bounds.first
  while pos >= bounds.first and pos < bounds.last:
    let next = content.find('\n', pos)
    let lineEnd = if next >= 0 and next < bounds.last: next else: bounds.last
    let line = content[pos..<lineEnd]
    if startsAssignmentLine(line, key):
      return (found: true, first: pos, last: lineEnd)
    if next < 0 or next >= bounds.last:
      break
    pos = next + 1

proc findDependencyLine(content, depName: string; bounds: tuple[first: int;
    last: int]): tuple[found: bool; first: int; last: int] =
  var pos = bounds.first
  while pos >= bounds.first and pos < bounds.last:
    let next = content.find('\n', pos)
    let lineEnd = if next >= 0 and next < bounds.last: next else: bounds.last
    let line = content[pos..<lineEnd]
    if startsDependencyLine(line, depName):
      return (found: true, first: pos, last: lineEnd)
    if next < 0 or next >= bounds.last:
      break
    pos = next + 1

proc upsertDependencyInSection*(content, sectionName: string;
    edit: DependencyEdit): DependencyEditResult =
  ## Insert or replace a dependency assignment in a TOML section.
  let line = dependencyLine(edit)
  let bounds = sectionBounds(content, sectionName)
  if bounds.first < 0:
    result.content = content.strip() & "\n\n[" & sectionName & "]\n" & line & "\n"
    result.changed = true
    return

  let existing = findDependencyLine(content, edit.name, bounds)
  if existing.found:
    result.content = content[0..<existing.first] & line &
      content[existing.last..^1]
    result.changed = true
  else:
    var prefix = content[0..<bounds.last]
    if prefix.len > 0 and prefix[^1] != '\n':
      prefix.add("\n")
    result.content = prefix & line & "\n" & content[bounds.last..^1]
    result.changed = true

proc removeDependencyFromSection*(content, sectionName, depName: string):
    DependencyEditResult =
  ## Remove a dependency assignment from a TOML section.
  let bounds = sectionBounds(content, sectionName)
  if bounds.first < 0:
    result.content = content
    return
  let existing = findDependencyLine(content, depName, bounds)
  if not existing.found:
    result.content = content
    return
  let removeStop =
    if existing.last < content.len and content[existing.last] == '\n':
      existing.last + 1
    else:
      existing.last
  let tail = if removeStop < content.len: content[removeStop..^1] else: ""
  result.content = content[0..<existing.first] & tail
  result.changed = true

proc parseVersionBumpKind*(value: string): VersionBumpKind =
  ## Parse a version bump selector such as `major` or `--patch`.
  var clean = value.strip().toLowerAscii()
  if clean.startsWith("--"):
    clean = clean[2..^1]
  case clean
  of "major":
    vbMajor
  of "minor":
    vbMinor
  of "patch":
    vbPatch
  else:
    raise newException(ValueError,
      "version bump must be one of: major, minor, patch")

proc parseSemVerComponent(value, version: string): int =
  if value.len == 0:
    raise newException(ValueError,
      "package.version must use SemVer MAJOR.MINOR.PATCH: " & version)
  if value.len > 1 and value[0] == '0':
    raise newException(ValueError,
      "SemVer numeric identifiers must not contain leading zeroes: " & version)
  for ch in value:
    if ch < '0' or ch > '9':
      raise newException(ValueError,
        "package.version must use SemVer MAJOR.MINOR.PATCH: " & version)
  result = parseInt(value)

proc bumpedSemVer*(version: string; kind: VersionBumpKind): string =
  ## Return `version` after incrementing the requested SemVer component.
  var suffixStart = version.len
  let prerelease = version.find('-')
  let build = version.find('+')
  if prerelease >= 0:
    suffixStart = min(suffixStart, prerelease)
  if build >= 0:
    suffixStart = min(suffixStart, build)

  let core = version[0..<suffixStart]
  let parts = core.split(".")
  if parts.len != 3:
    raise newException(ValueError,
      "package.version must use SemVer MAJOR.MINOR.PATCH: " & version)

  var major = parseSemVerComponent(parts[0], version)
  var minor = parseSemVerComponent(parts[1], version)
  var patch = parseSemVerComponent(parts[2], version)

  case kind
  of vbMajor:
    inc major
    minor = 0
    patch = 0
  of vbMinor:
    inc minor
    patch = 0
  of vbPatch:
    inc patch

  result = $major & "." & $minor & "." & $patch

proc replaceVersionLine(content: string; line: tuple[found: bool; first: int;
    last: int]; newVersion: string): DependencyEditResult =
  if not line.found:
    result.content = content
    return
  let oldLine = content[line.first..<line.last]
  let eq = oldLine.find('=')
  if eq < 0:
    result.content = content
    return
  var valueStart = eq + 1
  while valueStart < oldLine.len and oldLine[valueStart] in {' ', '\t'}:
    inc valueStart
  result.content = content[0..<line.first] & oldLine[0..<valueStart] &
    toTomlString(newVersion) & content[line.last..^1]
  result.changed = true

proc updatePackageVersionContent*(content, newVersion: string):
    DependencyEditResult =
  ## Replace the `[package]` version assignment in raw `bau.toml` content.
  let bounds = sectionBounds(content, "package")
  if bounds.first < 0:
    raise newException(ValueError, "[package] section is required")
  let line = findAssignmentLine(content, "version", bounds)
  if not line.found:
    raise newException(ValueError, "package.version is required")
  result = replaceVersionLine(content, line, newVersion)

proc updateNimbleVersionContent*(content, newVersion: string):
    DependencyEditResult =
  ## Replace the first top-level Nimble `version =` assignment.
  let bounds = (first: 0, last: content.len)
  let line = findAssignmentLine(content, "version", bounds)
  if not line.found:
    raise newException(ValueError,
      "could not find version assignment in .nimble file")
  result = replaceVersionLine(content, line, newVersion)

proc validateConfig(content, path: string) =
  discard parseBauConfig(content, path)

proc bumpPackageVersion*(projectDir: string; kind: VersionBumpKind;
    dryRun = false): VersionBumpResult =
  ## Bump `[package].version` and an existing generated Nimble file.
  let configPath = projectDir / ConfigFileName
  let before = readFileChecked(configPath)
  let cfg = parseBauConfig(before, configPath)
  if cfg.package.version.len == 0:
    raise newException(ValueError, "package.version is required")

  result.oldVersion = cfg.package.version
  result.newVersion = bumpedSemVer(cfg.package.version, kind)

  let edited = updatePackageVersionContent(before, result.newVersion)
  validateConfig(edited.content, configPath)
  result.configChanged = edited.changed
  if not dryRun:
    saveFile(configPath, edited.content)

  if cfg.package.name.len > 0:
    let nimblePath = projectDir / (cfg.package.name & ".nimble")
    if fileExists(nimblePath):
      let nimbleBefore = readFileChecked(nimblePath)
      let nimbleEdited = updateNimbleVersionContent(nimbleBefore,
        result.newVersion)
      result.nimblePath = nimblePath
      result.nimbleChanged = nimbleEdited.changed
      if not dryRun:
        saveFile(nimblePath, nimbleEdited.content)

proc addDependency*(projectDir: string; edit: DependencyEdit) =
  ## Add or update a dependency entry in a project's `bau.toml`.
  let configPath = projectDir / ConfigFileName
  let before = readFileChecked(configPath)
  validateConfig(before, configPath)
  let edited = upsertDependencyInSection(before, "dependencies", edit)
  validateConfig(edited.content, configPath)
  saveFile(configPath, edited.content)

proc removeDependency*(projectDir, depName: string) =
  ## Remove a dependency entry from a project's `bau.toml`.
  let configPath = projectDir / ConfigFileName
  let before = readFileChecked(configPath)
  let cfg = parseBauConfig(before, configPath)
  if not cfg.deps.hasKey(depName):
    raise newException(ValueError, "dependency not found: " & depName)
  let edited = removeDependencyFromSection(before, "dependencies", depName)
  if not edited.changed:
    raise newException(ValueError, "dependency not found: " & depName)
  validateConfig(edited.content, configPath)
  saveFile(configPath, edited.content)

proc writePatchEntry*(projectDir, depName, depPath: string) =
  ## Add or update a `[patch]` entry in a project's `bau.toml`.
  if depName.len == 0 or depPath.len == 0:
    raise newException(ValueError, "patch requires dependency name and path")
  let configPath = projectDir / ConfigFileName
  let before = readFileChecked(configPath)
  validateConfig(before, configPath)
  let edit = DependencyEdit(name: depName, path: depPath)
  let edited = upsertDependencyInSection(before, "patch", edit)
  validateConfig(edited.content, configPath)
  saveFile(configPath, edited.content)
