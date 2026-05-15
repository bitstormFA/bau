## Scans Nim modules, imports, and target candidates.

import std/[algorithm, options, os, strutils, tables]
import bau/[config, util]

type
  NimModuleInfo* = object ## Lightweight facts extracted from a Nim source file.
    path*: string ## Project-relative module path.
    moduleName*: string ## Filename stem used as the module name.
    imports*: seq[string] ## Non-stdlib modules imported by the file.
    includes*: seq[string] ## Non-stdlib modules included by the file.
    isMainModule*: bool ## True when the file references `isMainModule`.

  NimDependencyEdge* = object ## Compiler-reported dependency edge.
    importer*: string ## Module that imports or depends on another module.
    imported*: string ## Module imported by `importer`.

proc isStdlibModule(name: string): bool =
  case name
  of "algorithm", "asyncdispatch", "asyncfile", "asyncnet", "base64",
      "bitops", "cgi", "complex", "critbits", "csv", "db_common",
      "deques", "distros", "dynlib", "endians", "envvars", "exitprocs",
      "files", "genasts", "hashes", "heapqueue", "httpclient", "httpcore",
      "htmlgen", "json", "locks", "logging", "macros", "math", "monotimes",
      "net", "nre", "oids", "options", "os", "osproc", "parsecfg",
      "parsecsv", "parsejson", "parseopt", "parsesql", "parseutils",
      "paths", "pegs", "posix", "random", "rdstdin", "re", "sequtils",
      "sets", "sha1", "sockets", "streams", "strformat", "strmisc",
      "strscans", "strtabs", "strutils", "sugar", "syncio", "tables",
      "terminal", "times", "typetraits", "unicode", "unittest", "uri",
      "xmlparser", "xmltree":
    true
  else:
    false

proc stripComment(line: string): string =
  var quote = '\0'
  var escaped = false
  for ch in line:
    if quote != '\0':
      result.add(ch)
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == quote:
        quote = '\0'
    elif ch == '#':
      break
    else:
      result.add(ch)
      if ch == '"' or ch == '\'':
        quote = ch

proc balance(expr: string): int =
  for ch in expr:
    case ch
    of '[', '(', '{':
      inc result
    of ']', ')', '}':
      dec result
    else:
      discard

proc statementComplete(stmt: string): bool =
  balance(stmt) <= 0 and not stmt.strip().endsWith(",")

proc splitTopLevel(expr: string): seq[string] =
  var depth = 0
  var token = ""
  for ch in expr:
    case ch
    of '[', '(', '{':
      inc depth
      token.add(ch)
    of ']', ')', '}':
      dec depth
      token.add(ch)
    of ',':
      if depth == 0:
        if token.strip().len > 0:
          result.add(token.strip())
        token = ""
      else:
        token.add(ch)
    else:
      token.add(ch)
  if token.strip().len > 0:
    result.add(token.strip())

proc cleanImportToken(token: string): string =
  result = token.strip().strip(chars = {'"', '\'', '(', ')'})
  for marker in [" as ", " except "]:
    let idx = result.find(marker)
    if idx >= 0:
      result = result[0..<idx].strip()
  if result.endsWith(".nim"):
    result = result[0..^5]
  result = result.replace("\\", "/")

proc addImport(imports: var seq[string]; token: string) =
  let value = cleanImportToken(token)
  if value.len == 0 or value == "std" or value.startsWith("std/"):
    return
  if "/" notin value and isStdlibModule(value):
    return
  imports.add(value)

proc addImportExpr(imports: var seq[string]; expr: string) =
  for token in splitTopLevel(expr):
    let clean = token.strip().strip(chars = {'"', '\'', '(', ')'})
    let bracket = clean.find("/[")
    if bracket >= 0 and clean.endsWith("]"):
      let prefix = clean[0..<bracket]
      let inside = clean[(bracket + 2)..^2]
      if prefix == "std":
        continue
      for item in splitTopLevel(inside):
        imports.addImport(prefix & "/" & item)
    else:
      imports.addImport(token)

proc processStatement(info: var NimModuleInfo; stmt: string) =
  let clean = stmt.strip()
  if clean.startsWith("import "):
    info.imports.addImportExpr(clean["import ".len..^1])
  elif clean.startsWith("from ") and " import " in clean:
    let moduleName = clean["from ".len..^1].split(" import ", 1)[0]
    info.imports.addImport(moduleName)
  elif clean.startsWith("include "):
    info.includes.addImportExpr(clean["include ".len..^1])

proc scanNimModule*(projectDir, path: string): NimModuleInfo =
  ## Scan one Nim module for imports, includes, and `isMainModule`.
  ##
  ## The scanner is intentionally lightweight and ignores stdlib imports.
  let absPath = if path.isAbsolute: path else: projectDir / path
  result.path = relativePath(absPath, projectDir).replace("\\", "/")
  result.moduleName = splitFile(absPath).name
  if not fileExists(absPath):
    return

  var stmt = ""
  for rawLine in readFileChecked(absPath).splitLines():
    let line = stripComment(rawLine).strip()
    if line.len == 0:
      continue
    if line.contains("isMainModule"):
      result.isMainModule = true
    if stmt.len > 0:
      stmt.add(" " & line)
      if statementComplete(stmt):
        result.processStatement(stmt)
        stmt = ""
    elif line.startsWith("import ") or line.startsWith("from ") or
        line.startsWith("include "):
      stmt = line
      if statementComplete(stmt):
        result.processStatement(stmt)
        stmt = ""
  if stmt.len > 0:
    result.processStatement(stmt)

  result.imports.sort()
  result.includes.sort()

proc scanProjectModules*(projectDir: string; cfg: BauConfig): seq[
    NimModuleInfo] =
  ## Scan project source and test directories for Nim modules.
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let absSource = projectDir / sourceDir
  if dirExists(absSource):
    for f in walkDirRec(absSource, yieldFilter = {pcFile}):
      if f.endsWith(".nim"):
        result.add(scanNimModule(projectDir, f))
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    for f in walkDirRec(testDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim"):
        result.add(scanNimModule(projectDir, f))
  result.sort(proc(a, b: NimModuleInfo): int = cmp(a.path, b.path))

proc compilerSearchPaths(projectDir: string; cfg: BauConfig): seq[string] =
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  result.add("--path:" & absolutePath(projectDir) / sourceDir)
  let depsDir = projectDir / "deps"
  if dirExists(depsDir):
    for kind, path in walkDir(depsDir):
      if kind == pcDir:
        result.add("--path:" & path)
  for name, dep in cfg.deps.pairs:
    if dep.path.isSome:
      let depPath = absolutePath(projectDir) / dep.path.get()
      if dirExists(depPath / "src"):
        result.add("--path:" & depPath / "src")
      result.add("--path:" & depPath)

proc parseDotEdges(content: string): seq[NimDependencyEdge] =
  for line in content.splitLines():
    let trimmed = line.strip()
    let arrow = trimmed.find("\" -> \"")
    if not trimmed.startsWith("\"") or arrow < 0:
      continue
    let left = trimmed[1..<arrow]
    let rightStart = arrow + "\" -> \"".len
    let rightEnd = trimmed.find("\"", rightStart)
    if rightEnd <= rightStart:
      continue
    let right = trimmed[rightStart..<rightEnd]
    if left.len > 0 and right.len > 0:
      result.add(NimDependencyEdge(importer: left, imported: right))

proc generatedDependFiles(projectDir, mainFile: string): seq[string] =
  let absMain = if mainFile.isAbsolute: mainFile else: projectDir / mainFile
  result.add(absMain.changeFileExt(".dot"))
  result.add(absMain.changeFileExt(".png"))
  result.add(projectDir / (splitFile(absMain).name & ".deps"))

proc runCompilerDepend(projectDir: string; cfg: BauConfig;
    mainFile: string): seq[NimDependencyEdge] =
  let absMain = if mainFile.isAbsolute: mainFile else: projectDir / mainFile
  if not fileExists(absMain):
    return
  let generatedFiles = generatedDependFiles(projectDir, mainFile)
  for file in generatedFiles:
    if fileExists(file):
      try:
        removeFile(file)
      except CatchableError:
        discard

  var args = @["genDepend", "--hints:off"]
  args.add(compilerSearchPaths(projectDir, cfg))
  args.add(mainFile)
  let (exitCode, _) = runCmd(detectNimCompiler(), args, projectDir)
  if exitCode == 0:
    let dotFile = absMain.changeFileExt(".dot")
    if fileExists(dotFile):
      result = parseDotEdges(readFileChecked(dotFile))
  for file in generatedFiles:
    if fileExists(file):
      try:
        removeFile(file)
      except CatchableError:
        discard

proc compilerDependencyEdges*(projectDir: string;
    cfg: BauConfig): seq[NimDependencyEdge] =
  ## Ask the Nim compiler for dependency edges for targets and tests.
  ##
  ## Failures are tolerated so source-level scanning can still provide results.
  var mains: seq[string]
  if cfg.build.main.len > 0:
    mains.add(cfg.build.main)
  for target in cfg.targets:
    if target.main.len > 0 and target.main notin mains:
      mains.add(target.main)
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    for file in walkDirRec(testDir, yieldFilter = {pcFile}):
      if file.endsWith(".nim"):
        let rel = relativePath(file, projectDir).replace("\\", "/")
        if rel.extractFilename != "thelper.nim" and rel notin mains:
          mains.add(rel)

  for mainFile in mains:
    result.add(runCompilerDepend(projectDir, cfg, mainFile))
  result.sort(proc(a, b: NimDependencyEdge): int =
    let byImporter = cmp(a.importer, b.importer)
    if byImporter != 0: byImporter else: cmp(a.imported, b.imported))
