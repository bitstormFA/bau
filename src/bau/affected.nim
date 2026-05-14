## Computes which Bau targets and tests are affected by changed files.

import std/[algorithm, os, sets, strutils, tables]
import bau/[config, lock, nimscan, util]

type
  AffectedReport* = object     ## Files and Bau work items affected by a change set.
    changedFiles*: seq[string] ## Changed paths relative to the project root.
    sourceFiles*: seq[string]  ## Source modules affected directly or transitively.
    targets*: seq[string]      ## Build target names affected by changed sources.
    tests*: seq[string]        ## Test files affected by changed sources or test config.
    tasks*: seq[string]        ## Task names affected by changed inputs.

proc gitChangedFiles*(projectDir: string; since: string = "HEAD"): seq[string] =
  ## Return files changed since a Git revision or ref.
  ##
  ## If Git cannot produce a diff, returns an empty sequence.
  let spec = if since.len > 0: since else: "HEAD"
  let (exitCode, output) = runCmd("git", ["diff", "--name-only", spec],
    projectDir)
  if exitCode != 0:
    return
  for line in output.splitLines():
    let file = line.strip()
    if file.len > 0:
      result.add(file.replace("\\", "/"))
  result.sort()

proc cleanRel(path: string): string =
  path.replace("\\", "/").strip(chars = {'/'})

proc hasPatternChars(path: string): bool =
  path.contains("*") or path.contains("?") or path.contains("[")

proc splitPath(path: string): seq[string] =
  for part in cleanRel(path).split('/'):
    if part.len > 0:
      result.add(part)

proc charClassMatches(pattern: string; start: int; ch: char;
    stop: var int): bool =
  var i = start + 1
  var negate = false
  if i < pattern.len and pattern[i] in {'!', '^'}:
    negate = true
    inc i

  var matched = false
  while i < pattern.len and pattern[i] != ']':
    if i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']':
      if ch >= pattern[i] and ch <= pattern[i + 2]:
        matched = true
      i += 3
    else:
      if ch == pattern[i]:
        matched = true
      inc i

  if i >= pattern.len:
    stop = start
    return ch == pattern[start]

  stop = i
  if negate: not matched else: matched

proc segmentMatches(pattern, text: string): bool =
  var p = 0
  var t = 0
  while p < pattern.len:
    case pattern[p]
    of '*':
      while p + 1 < pattern.len and pattern[p + 1] == '*':
        inc p
      if p + 1 >= pattern.len:
        return true
      let rest = pattern[(p + 1)..^1]
      var pos = t
      while pos <= text.len:
        let tail = if pos < text.len: text[pos..^1] else: ""
        if segmentMatches(rest, tail):
          return true
        inc pos
      return false
    of '?':
      if t >= text.len:
        return false
      inc p
      inc t
    of '[':
      if t >= text.len:
        return false
      var stop = p
      if not charClassMatches(pattern, p, text[t], stop):
        return false
      p = stop + 1
      inc t
    else:
      if t >= text.len or pattern[p] != text[t]:
        return false
      inc p
      inc t
  t == text.len

proc pathSegmentsMatch(pattern, path: seq[string]; p, f: int): bool =
  if p >= pattern.len:
    return f >= path.len
  if pattern[p] == "**":
    var next = f
    while next <= path.len:
      if pathSegmentsMatch(pattern, path, p + 1, next):
        return true
      inc next
    return false
  f < path.len and segmentMatches(pattern[p], path[f]) and
    pathSegmentsMatch(pattern, path, p + 1, f + 1)

proc pathMatchesPattern(pattern, file: string): bool =
  let cleanPattern = cleanRel(pattern)
  let cleanFile = cleanRel(file)
  if cleanPattern.len == 0:
    return false
  if not hasPatternChars(cleanPattern):
    return cleanFile == cleanPattern or cleanFile.startsWith(cleanPattern & "/")
  pathSegmentsMatch(splitPath(cleanPattern), splitPath(cleanFile), 0, 0)

proc isProjectConfigChange(file: string): bool =
  let clean = cleanRel(file)
  clean == ConfigFileName or clean == LocalConfigFileName or
    clean == "nim.cfg" or clean == "config.nims" or clean.endsWith(".nimble")

proc isBuildInputChange(file: string): bool =
  let clean = cleanRel(file)
  isProjectConfigChange(clean) or clean == LockFileName or
    clean.startsWith("deps/") or clean.startsWith("vendor/")

proc isTestConfigChange(file: string): bool =
  let clean = cleanRel(file)
  clean == "tests/config.nims" or clean == "tests/tester.nim"

proc allModuleFiles(projectDir: string; cfg: BauConfig): seq[string] =
  for info in scanProjectModules(projectDir, cfg):
    result.add(info.path)
  result.sort()

proc allTestFiles(projectDir: string): seq[string] =
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    for file in walkDirRec(testDir, yieldFilter = {pcFile}):
      if file.endsWith(".nim"):
        let rel = relativePath(file, projectDir).replace("\\", "/")
        let name = rel.extractFilename
        if name != "tester.nim" and "thelper" notin name:
          result.add(rel)
  result.sort()

proc allTargetNames(cfg: BauConfig): seq[string] =
  if cfg.build.main.len > 0:
    let defaultName = defaultTargetName(cfg)
    if defaultName.len > 0:
      result.add(defaultName)
  for target in cfg.targets:
    if target.name.len > 0:
      result.add(target.name)
  result.sort()

proc allTaskNames(cfg: BauConfig): seq[string] =
  for task in cfg.tasks:
    if task.name.len > 0:
      result.add(task.name)
  result.sort()

proc pathKey(path: string): string =
  path.changeFileExt("").replace("\\", "/")

proc moduleKeys(info: NimModuleInfo; cfg: BauConfig): seq[string] =
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let noExt = pathKey(info.path)
  result.add(noExt)
  if noExt.startsWith(sourceDir & "/"):
    result.add(noExt[(sourceDir.len + 1)..^1])
  if noExt.startsWith("tests/"):
    result.add(noExt["tests/".len..^1])
  result.add(info.moduleName)

proc normalizeCompilerImport(imported, importerFile: string;
    cfg: BauConfig): string =
  let clean = imported.replace("\\", "/")
  if clean.startsWith("../") or clean.startsWith("./"):
    let joined = normalizedPath(parentDir(pathKey(importerFile)) / clean).
      replace("\\", "/")
    let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
    if joined.startsWith(sourceDir & "/"):
      return joined[(sourceDir.len + 1)..^1]
    return joined
  result = clean

proc affectedSources(projectDir: string; cfg: BauConfig;
    changed: openArray[string]): seq[string] =
  let modules = scanProjectModules(projectDir, cfg)
  var moduleToFile = initTable[string, string]()
  for info in modules:
    for key in moduleKeys(info, cfg):
      if not moduleToFile.hasKey(key):
        moduleToFile[key] = info.path

  var reverse = initTable[string, seq[string]]()
  for info in modules:
    for imported in info.imports:
      if moduleToFile.hasKey(imported):
        reverse.mgetOrPut(moduleToFile[imported], @[]).add(info.path)
    for included in info.includes:
      if moduleToFile.hasKey(included):
        reverse.mgetOrPut(moduleToFile[included], @[]).add(info.path)

  for edge in compilerDependencyEdges(projectDir, cfg):
    if moduleToFile.hasKey(edge.importer):
      let importerFile = moduleToFile[edge.importer]
      let importedKey = normalizeCompilerImport(edge.imported, importerFile, cfg)
      if moduleToFile.hasKey(importedKey):
        reverse.mgetOrPut(moduleToFile[importedKey], @[]).add(importerFile)

  var affected = initHashSet[string]()
  var queue: seq[string]
  for file in changed:
    let clean = file.replace("\\", "/")
    if clean.endsWith(".nim"):
      affected.incl(clean)
      queue.add(clean)

  var idx = 0
  while idx < queue.len:
    let file = queue[idx]
    inc idx
    if reverse.hasKey(file):
      for dependent in reverse[file]:
        if not affected.contains(dependent):
          affected.incl(dependent)
          queue.add(dependent)

  for file in affected:
    result.add(file)
  result.sort()

proc taskAffected(task: TaskInfo; changed: openArray[string]): bool =
  for input in task.inputs:
    for file in changed:
      if pathMatchesPattern(input, file):
        return true

proc computeAffectedFromChanges*(cfg: BauConfig; projectDir: string;
    changedFiles: openArray[string]): AffectedReport =
  ## Compute affected sources, targets, tests, and tasks from explicit paths.
  for file in changedFiles:
    result.changedFiles.add(file.replace("\\", "/"))
  result.changedFiles.sort()

  var projectConfigChanged = false
  var buildInputChanged = false
  var testConfigChanged = false
  for file in result.changedFiles:
    if isProjectConfigChange(file):
      projectConfigChanged = true
    if isBuildInputChange(file):
      buildInputChanged = true
    if isTestConfigChange(file):
      testConfigChanged = true

  if buildInputChanged:
    result.sourceFiles = allModuleFiles(projectDir, cfg)
  else:
    result.sourceFiles = affectedSources(projectDir, cfg, result.changedFiles)

  let affectedSet = toHashSet(result.sourceFiles)
  if buildInputChanged:
    result.targets = allTargetNames(cfg)
  else:
    let defaultName = defaultTargetName(cfg)
    if cfg.build.main.len > 0 and affectedSet.contains(cfg.build.main):
      result.targets.add(defaultName)
    for target in cfg.targets:
      if target.main.len > 0 and affectedSet.contains(target.main):
        result.targets.add(target.name)

  if buildInputChanged or testConfigChanged:
    result.tests = allTestFiles(projectDir)
  else:
    for file in result.sourceFiles:
      if file.startsWith("tests/") and file.endsWith(".nim"):
        let name = file.extractFilename
        if name != "tester.nim" and "thelper" notin name:
          result.tests.add(file)

  if projectConfigChanged:
    result.tasks = allTaskNames(cfg)
  else:
    for task in cfg.tasks:
      if taskAffected(task, result.changedFiles):
        result.tasks.add(task.name)
  result.targets.sort()
  result.tests.sort()
  result.tasks.sort()

proc computeAffected*(cfg: BauConfig; projectDir: string;
    since: string = "HEAD"): AffectedReport =
  ## Compute affected work from files changed since a Git revision or ref.
  computeAffectedFromChanges(cfg, projectDir, gitChangedFiles(projectDir, since))
