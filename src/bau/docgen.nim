## Discovers modules and orchestrates Nim API documentation generation.

import std/[algorithm, json, options, os, sets, strutils, tables]
import bau/[config, features, util]

const DocManifestName* = ".bau-docs-manifest" ## Manifest listing files produced by `bau doc`.

type
  DocBuildOptions* = object ## Runtime options for API documentation generation.
    profile*: string ## Profile whose flags are applied to Nim doc.
    features*: FeatureSelection ## Enabled features applied to Nim doc.
    verbose*: bool ## Whether Nim doc commands are printed.
    outDir*: string ## Output directory override.
    entrypoints*: seq[string] ## Additional documentation entrypoint files.
    skipExamples*: bool ## Skip compiling runnable examples.
    includePrivate*: bool ## Include private symbols in generated API docs.
    noIndex*: bool ## Suppress Bau's documentation index generation.

  DocModule* = object ## One Nim source file selected for documentation.
    file*: string ## Absolute source file path.
    relPath*: string ## Project-relative source file path.
    sourceRelPath*: string ## Source-root-relative path used for output naming.
    moduleName*: string ## Dotted module name shown in reports.
    outputPath*: string ## Expected generated HTML path.
    entrypoint*: bool ## True when selected as an explicit entrypoint.

  DocDiagnostic* = object ## Documentation-quality diagnostic.
    kind*: string ## Stable diagnostic kind.
    file*: string ## Project-relative file path.
    message*: string ## Human-readable diagnostic message.

  DocCommandResult* = object ## Result of one Nim doc invocation.
    moduleName*: string ## Module documented by the command.
    file*: string ## Project-relative source path.
    outputPath*: string ## Expected generated HTML path.
    command*: seq[string] ## Full command argv.
    exitCode*: int ## Process exit code.
    output*: string ## Combined compiler output.

  DocBuildReport* = object ## Complete result of a documentation build.
    ok*: bool ## True when every Nim doc invocation succeeded.
    outDir*: string ## Absolute output directory.
    indexPath*: string ## Expected generated index path.
    modules*: seq[DocModule] ## Modules selected for documentation.
    diagnostics*: seq[DocDiagnostic] ## Non-fatal documentation diagnostics.
    commands*: seq[DocCommandResult] ## Nim doc command results.
    generatedFiles*: seq[string] ## Generated files relative to `outDir`.

proc cleanRel(path: string): string =
  path.replace("\\", "/").strip(chars = {'/'})

proc cleanAbs(path: string): string =
  absolutePath(path).replace("\\", "/").strip(chars = {'/'})

proc isInside(path, dir: string): bool =
  let cleanPath = cleanAbs(path)
  let cleanDir = cleanAbs(dir)
  cleanPath == cleanDir or cleanPath.startsWith(cleanDir & "/")

proc relTo(path, dir: string): string =
  if isInside(path, dir):
    cleanRel(relativePath(path, dir))
  else:
    path.replace("\\", "/")

proc projectPath(projectDir, path: string): string =
  if path.isAbsolute:
    absolutePath(path)
  else:
    absolutePath(projectDir / path)

proc hasGlobSegment(segment: string): bool =
  segment.contains("*") or segment.contains("?")

proc hasGlob(pattern: string): bool =
  for segment in cleanRel(pattern).split("/"):
    if segment == "**" or hasGlobSegment(segment):
      return true

proc segmentMatches(pattern, text: string): bool =
  proc matchAt(pi, ti: int): bool =
    if pi == pattern.len:
      return ti == text.len
    if pattern[pi] == '*':
      for nextTi in ti..text.len:
        if matchAt(pi + 1, nextTi):
          return true
      return false
    if ti >= text.len:
      return false
    if pattern[pi] == '?' or pattern[pi] == text[ti]:
      return matchAt(pi + 1, ti + 1)
    false

  matchAt(0, 0)

proc globMatches(pattern, path: string): bool =
  let patternParts = cleanRel(pattern).split("/")
  let pathParts = cleanRel(path).split("/")

  proc matchParts(pi, si: int): bool =
    if pi == patternParts.len:
      return si == pathParts.len
    if patternParts[pi] == "**":
      for nextSi in si..pathParts.len:
        if matchParts(pi + 1, nextSi):
          return true
      return false
    if si >= pathParts.len:
      return false
    if segmentMatches(patternParts[pi], pathParts[si]):
      return matchParts(pi + 1, si + 1)
    false

  matchParts(0, 0)

proc pathMatchesPattern(relProject, relSource, pattern: string): bool =
  let cleanPattern = cleanRel(pattern)
  if cleanPattern.len == 0:
    return false
  if hasGlob(cleanPattern):
    return globMatches(cleanPattern, relProject) or
      globMatches(cleanPattern, relSource)
  relProject == cleanPattern or relProject.startsWith(cleanPattern & "/") or
    relSource == cleanPattern or relSource.startsWith(cleanPattern & "/")

proc matchesAny(relProject, relSource: string; patterns: openArray[
    string]): bool =
  for pattern in patterns:
    if pathMatchesPattern(relProject, relSource, pattern):
      return true

proc globBase(pattern: string): string =
  var parts: seq[string]
  for segment in cleanRel(pattern).split("/"):
    if segment == "**" or hasGlobSegment(segment):
      break
    parts.add(segment)
  parts.join("/")

proc defaultDocSkip(relProject, relSource: string): bool =
  if relProject.len == 0 or relProject.startsWith(".."):
    return true
  if relProject.startsWith(BuildDirName & "/") or
      relProject.startsWith("deps/") or relProject.startsWith("nimcache/") or
      relProject.startsWith("nimblecache/"):
    return true
  let parts = relSource.split("/")
  for part in parts:
    if part in ["private", "internal"]:
      return true
  let name = extractFilename(relSource)
  name.startsWith(".") or name.endsWith("_test.nim")

proc outputPathFor(outDir, sourceRelPath: string): string =
  outDir / changeFileExt(sourceRelPath, "html")

proc idxPathFor(outDir, sourceRelPath: string): string =
  outDir / changeFileExt(sourceRelPath, "idx")

proc addModule(modules: var seq[DocModule]; seen: var HashSet[string];
    projectDir, sourceDir, outDir, file: string; entrypoint: bool) =
  if not fileExists(file) or not file.endsWith(".nim"):
    return

  let absFile = absolutePath(file)
  let key = cleanAbs(absFile)
  if seen.contains(key):
    if entrypoint:
      for module in modules.mitems:
        if cleanAbs(module.file) == key:
          module.entrypoint = true
          break
    return
  seen.incl(key)

  let relProject = relTo(absFile, projectDir)
  let relSource = if isInside(absFile, sourceDir): relTo(absFile, sourceDir)
                  else: relProject
  modules.add(DocModule(
    file: absFile,
    relPath: relProject,
    sourceRelPath: relSource,
    moduleName: changeFileExt(relSource, "").replace("/", "."),
    outputPath: outputPathFor(outDir, relSource),
    entrypoint: entrypoint))

proc addPatternModules(modules: var seq[DocModule]; seen: var HashSet[string];
    projectDir, sourceDir, outDir, pattern: string) =
  let cleanPattern = cleanRel(pattern)
  if cleanPattern.len == 0:
    return
  if not hasGlob(cleanPattern):
    let absPath = projectPath(projectDir, cleanPattern)
    if fileExists(absPath):
      modules.addModule(seen, projectDir, sourceDir, outDir, absPath, false)
    elif dirExists(absPath):
      for file in walkDirRec(absPath, yieldFilter = {pcFile}):
        if file.endsWith(".nim"):
          modules.addModule(seen, projectDir, sourceDir, outDir, file, false)
    return

  let base = globBase(cleanPattern)
  let baseDir = if base.len > 0: projectDir / base else: projectDir
  if not dirExists(baseDir):
    return
  for file in walkDirRec(baseDir, yieldFilter = {pcFile}):
    if not file.endsWith(".nim"):
      continue
    let relProject = relTo(file, projectDir)
    let relSource = if isInside(file, sourceDir): relTo(file, sourceDir)
                    else: relProject
    if pathMatchesPattern(relProject, relSource, cleanPattern):
      modules.addModule(seen, projectDir, sourceDir, outDir, file, false)

proc defaultEntrypoints(cfg: BauConfig; projectDir, sourceDir: string): seq[string] =
  if cfg.build.main.len > 0:
    result.add(projectPath(projectDir, cfg.build.main))

  if cfg.package.name.len > 0:
    let packageRoot = sourceDir / (cfg.package.name & ".nim")
    if fileExists(packageRoot):
      result.add(packageRoot)

  for target in cfg.targets:
    if target.main.len > 0:
      result.add(projectPath(projectDir, target.main))

proc discoverDocModules*(cfg: BauConfig; projectDir: string;
    opts: DocBuildOptions = DocBuildOptions()): seq[DocModule] =
  ## Discover Nim modules that should be documented for a project.
  ##
  ## Explicit entrypoints and include/exclude patterns are resolved before the
  ## final list is sorted by project-relative path.
  let sourceRel = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let sourceDir = projectPath(projectDir, sourceRel)
  let outDir = if opts.outDir.len > 0: projectPath(projectDir, opts.outDir)
               elif cfg.docs.outDir.len > 0: projectPath(projectDir,
                   cfg.docs.outDir)
               else: projectPath(projectDir, "docs")

  var seen = initHashSet[string]()
  var entries: seq[string]
  if cfg.docs.entrypoints.len > 0 or opts.entrypoints.len > 0:
    for entry in cfg.docs.entrypoints:
      entries.add(projectPath(projectDir, entry))
    for entry in opts.entrypoints:
      entries.add(projectPath(projectDir, entry))
  else:
    entries = defaultEntrypoints(cfg, projectDir, sourceDir)

  for entry in entries:
    result.addModule(seen, projectDir, sourceDir, outDir, entry, true)

  if cfg.docs.includeFiles.len > 0:
    for pattern in cfg.docs.includeFiles:
      result.addPatternModules(seen, projectDir, sourceDir, outDir, pattern)
  elif dirExists(sourceDir):
    for file in walkDirRec(sourceDir, yieldFilter = {pcFile}):
      if not file.endsWith(".nim"):
        continue
      let relProject = relTo(file, projectDir)
      let relSource = relTo(file, sourceDir)
      if not defaultDocSkip(relProject, relSource):
        result.addModule(seen, projectDir, sourceDir, outDir, file, false)

  var filtered: seq[DocModule]
  for module in result:
    if not matchesAny(module.relPath, module.sourceRelPath,
        cfg.docs.excludeFiles):
      filtered.add(module)
  result = filtered
  result.sort(proc(a, b: DocModule): int = cmp(a.relPath, b.relPath))

proc moduleHasTopDoc(path: string): bool =
  for line in lines(path):
    let clean = line.strip()
    if clean.len == 0:
      continue
    if clean.startsWith("##"):
      return true
    if clean.startsWith("#"):
      continue
    return false
  false

proc collectDiagnostics(modules: openArray[DocModule]): seq[DocDiagnostic] =
  for module in modules:
    if not moduleHasTopDoc(module.file):
      result.add(DocDiagnostic(kind: "missing-module-doc",
        file: module.relPath,
        message: "module has no top-level Nim doc comment"))

proc addUnique(paths: var seq[string]; path: string) =
  if path.len > 0 and dirExists(path):
    let clean = absolutePath(path)
    if clean notin paths:
      paths.add(clean)

proc docSearchPaths(cfg: BauConfig; projectDir: string;
    selection: FeatureSelection): seq[string] =
  let sourceRel = if cfg.build.source.len > 0: cfg.build.source else: "src"
  result.addUnique(projectPath(projectDir, sourceRel))

  let depsDir = projectDir / "deps"
  if dirExists(depsDir):
    for kind, path in walkDir(depsDir):
      if kind == pcDir:
        result.addUnique(path)

  for name, dep in cfg.deps.pairs:
    if dep.path.isSome and dependencyEnabled(cfg, name, dep, selection):
      let depPath = projectPath(projectDir, dep.path.get())
      result.addUnique(depPath / "src")
      result.addUnique(depPath)

proc docCompilerFlags(cfg: BauConfig; projectDir: string;
    opts: DocBuildOptions): seq[string] =
  let prof = if opts.profile.len > 0 and cfg.profiles.hasKey(opts.profile):
               resolveProfile(cfg.profiles, opts.profile)
             else:
               initProfileInfo()

  result.add(prof.flags)
  if prof.gc.len > 0:
    result.add("--mm:" & prof.gc)
  else:
    result.add("--mm:orc")

  for key, val in prof.define.pairs:
    if val.len > 0:
      result.add("-d:" & key & "=" & val)
    else:
      result.add("-d:" & key)

  result.add(compilerFeatureFlags(opts.features))

  let backend = if prof.backend.len > 0: prof.backend else: cfg.build.backend
  if backend.len > 0:
    result.add("--backend:" & backend)

  let color = currentColorMode()
  if color == "always":
    result.add("--colors:on")
  elif color == "never":
    result.add("--colors:off")

  result.add(cfg.docs.flags)
  result.add("--hints:off")

  for path in docSearchPaths(cfg, projectDir, opts.features):
    result.add("--path:" & path)

proc effectiveOutDir(cfg: BauConfig; projectDir: string;
    opts: DocBuildOptions): string =
  if opts.outDir.len > 0:
    projectPath(projectDir, opts.outDir)
  elif cfg.docs.outDir.len > 0:
    projectPath(projectDir, cfg.docs.outDir)
  else:
    projectPath(projectDir, "docs")

proc effectiveDocRoot(cfg: BauConfig): string =
  if cfg.docs.docRoot.len > 0: cfg.docs.docRoot else: "@path"

proc shouldBuildIndex(cfg: BauConfig; opts: DocBuildOptions): bool =
  cfg.docs.index and not opts.noIndex

proc shouldRunExamples(cfg: BauConfig; opts: DocBuildOptions): bool =
  cfg.docs.runExamples and not opts.skipExamples

proc shouldIncludePrivate(cfg: BauConfig; opts: DocBuildOptions): bool =
  cfg.docs.includePrivate or opts.includePrivate

proc docArgs(cfg: BauConfig; projectDir, outDir: string; module: DocModule;
    opts: DocBuildOptions): seq[string] =
  result = @["doc"]
  result.add(docCompilerFlags(cfg, projectDir, opts))
  result.add("--outdir:" & outDir)
  result.add("--docRoot:" & effectiveDocRoot(cfg))
  if cfg.docs.project:
    result.add("--project")
  if shouldBuildIndex(cfg, opts):
    result.add("--index:on")
  else:
    result.add("--index:off")
  if not shouldRunExamples(cfg, opts):
    result.add("--docCmd:skip")
  if shouldIncludePrivate(cfg, opts):
    result.add("--docInternal")
  if cfg.docs.sourceUrl.len > 0:
    result.add("--docSeeSrcUrl:" & cfg.docs.sourceUrl)
  result.add(module.file)

proc removeEmptyDirs(dir, stopDir: string) =
  var current = dir
  while current.len > 0 and isInside(current, stopDir) and current != stopDir:
    var empty = true
    for kind, path in walkDir(current):
      discard kind
      discard path
      empty = false
      break
    if not empty:
      break
    try:
      removeDir(current)
    except OSError:
      break
    current = parentDir(current)

proc cleanPreviousManifest(outDir: string) =
  let manifestPath = outDir / DocManifestName
  if not fileExists(manifestPath):
    return
  for line in lines(manifestPath):
    let rel = cleanRel(line)
    if rel.len == 0 or rel.startsWith("#") or rel.startsWith(".."):
      continue
    let path = outDir / rel
    if fileExists(path):
      removeFile(path)
      removeEmptyDirs(parentDir(path), outDir)
  removeFile(manifestPath)

proc expectedGeneratedFiles(outDir: string; modules: openArray[DocModule];
    index: bool): seq[string] =
  for module in modules:
    result.add(module.outputPath)
    result.add(idxPathFor(outDir, module.sourceRelPath))
  if index:
    result.add(outDir / "theindex.html")
    result.add(outDir / "dochack.js")
    result.add(outDir / "nimdoc.out.css")
  result.sort()

proc relativeGenerated(outDir: string; files: openArray[string]): seq[string] =
  for file in files:
    if fileExists(file):
      result.add(relTo(file, outDir))
  result.sort()

proc writeManifest(outDir: string; relFiles: openArray[string]) =
  var content = "# generated by bau doc\n"
  for file in relFiles:
    content.add(file & "\n")
  saveFile(outDir / DocManifestName, content)

proc buildApiDocs*(cfg: BauConfig; projectDir: string;
    opts: DocBuildOptions = DocBuildOptions()): DocBuildReport =
  ## Generate Nim API documentation and return a structured build report.
  ##
  ## Previously generated files tracked by Bau's manifest are removed before
  ## invoking Nim doc.
  let outDir = effectiveOutDir(cfg, projectDir, opts)
  result.outDir = outDir
  result.indexPath = outDir / "theindex.html"
  result.modules = discoverDocModules(cfg, projectDir, opts)
  result.diagnostics = collectDiagnostics(result.modules)

  if result.modules.len == 0:
    raise newException(ValueError, "no Nim modules found for documentation")

  createDir(outDir)
  cleanPreviousManifest(outDir)

  let nim = detectNimCompiler()
  result.ok = true
  for module in result.modules:
    let args = docArgs(cfg, projectDir, outDir, module, opts)
    if opts.verbose:
      info("documenting " & module.relPath)
      echo nim & " " & args.join(" ")
    let (exitCode, output) = runCmd(nim, args, projectDir)
    result.commands.add(DocCommandResult(
      moduleName: module.moduleName,
      file: module.relPath,
      outputPath: module.outputPath,
      command: @[nim] & args,
      exitCode: exitCode,
      output: output))
    if exitCode != 0:
      result.ok = false
      break

  result.generatedFiles = relativeGenerated(outDir,
    expectedGeneratedFiles(outDir, result.modules, shouldBuildIndex(cfg, opts)))
  if result.ok:
    writeManifest(outDir, result.generatedFiles)

proc primaryDocPath*(report: DocBuildReport): string =
  ## Return the preferred HTML file to open for a documentation report.
  if report.indexPath.len > 0 and fileExists(report.indexPath) and
      relTo(report.indexPath, report.outDir) in report.generatedFiles:
    return report.indexPath
  for module in report.modules:
    if fileExists(module.outputPath):
      return module.outputPath

proc docReportJson*(report: DocBuildReport): JsonNode =
  ## Convert a documentation build report to JSON.
  var modules = newJArray()
  for module in report.modules:
    modules.add(%*{
      "file": module.relPath,
      "sourceRelPath": module.sourceRelPath,
      "module": module.moduleName,
      "output": module.outputPath,
      "entrypoint": module.entrypoint
    })

  var diagnostics = newJArray()
  for diagnostic in report.diagnostics:
    diagnostics.add(%*{
      "kind": diagnostic.kind,
      "file": diagnostic.file,
      "message": diagnostic.message
    })

  var commands = newJArray()
  for command in report.commands:
    commands.add(%*{
      "module": command.moduleName,
      "file": command.file,
      "output": command.outputPath,
      "command": command.command,
      "exitCode": command.exitCode,
      "compilerOutput": command.output
    })

  %*{
    "ok": report.ok,
    "outDir": report.outDir,
    "indexPath": report.indexPath,
    "primaryPath": primaryDocPath(report),
    "modules": modules,
    "diagnostics": diagnostics,
    "commands": commands,
    "generatedFiles": report.generatedFiles
  }
