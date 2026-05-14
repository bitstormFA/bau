## Exposes Bau operations behind CLI and MCP entry points.

import std/[algorithm, json, options, os, sets, strutils, tables, times]
import bau/[affected, atlas, build, config, depscheck, features, fingerprint,
  init, lock, metadata, nimble, taskcache, util, workspace, configedit, docgen,
  installer]

type
  OperationOptions* = object ## Shared options accepted by CLI and MCP operations.
    profile*: string ## Build or documentation profile.
    features*: seq[string] ## Explicit feature names requested by the caller.
    allFeatures*: bool ## Enable every non-default feature.
    noDefaultFeatures*: bool ## Skip the default feature.
    since*: string ## Git revision or ref for affected analysis.
    taskName*: string ## Task name for task-oriented operations.
    queryKind*: string ## Query mode such as `deps` or `why`.
    queryName*: string ## Target, task, feature, or dependency being queried.
    runArgs*: seq[string] ## Arguments passed through to `run`.
    filter*: string ## Optional dependency or test filter.
    precise*: string ## Exact dependency revision for update operations.
    verbose*: bool ## Whether nested commands should print details.
    allTargets*: bool ## Select all eligible targets.
    update*: bool ## Request dependency update rather than sync.
    force*: bool ## Allow overwriting or bypass cached state.
    dryRun*: bool ## Plan the operation without writing when supported.
    targetName*: string ## Explicit build or install target name.
    installAction*: string ## Install action text such as `install` or `remove`.
    installDir*: string ## Installation directory override.
    depName*: string ## Dependency name for add/remove operations.
    depVersion*: string ## Dependency version requirement.
    depGit*: string ## Dependency Git URL.
    depTag*: string ## Dependency Git tag.
    depBranch*: string ## Dependency Git branch.
    depRev*: string ## Dependency exact Git revision.
    depPath*: string ## Dependency local path.
    depRegistry*: string ## Dependency registry source.
    depOptional*: bool ## Whether the dependency is optional.
    initName*: string ## Package name for project initialization.
    initKind*: string ## Project kind for initialization.
    initDir*: string ## Directory for project initialization.
    convertPath*: string ## Nimble file or directory to convert.
    formatVersion*: int ## Metadata JSON format version.
    docOutDir*: string ## Documentation output directory override.
    docEntrypoints*: seq[string] ## Additional documentation entrypoints.
    docSkipExamples*: bool ## Skip compiling runnable examples during docs.
    docIncludePrivate*: bool ## Include private symbols in docs.
    docNoIndex*: bool ## Suppress generated docs index.

  CompileCommandsMemberResult* = object ## Per-member compile commands summary.
    path*: string ## Workspace member path.
    name*: string ## Workspace member package name.
    entries*: int ## Number of compile command entries written.

  CompileCommandsResult* = object ## Result of generating compile commands.
    workspace*: bool ## True when multiple workspace members were processed.
    root*: string ## Workspace or project root.
    path*: string ## Single-project compile commands path.
    entries*: int ## Single-project entry count.
    members*: seq[CompileCommandsMemberResult] ## Workspace member summaries.

  OperationResult* = object ## Standard result returned by operation APIs.
    ok*: bool ## True when the operation succeeded.
    json*: JsonNode ## Machine-readable result payload.
    output*: string ## Human-readable or compiler output.

proc defaultOperationOptions*(): OperationOptions =
  ## Return default operation options shared by CLI and MCP callers.
  OperationOptions(profile: "dev", since: "HEAD", formatVersion: 1)

proc featureSelection(opts: OperationOptions;
    cfg: BauConfig): FeatureSelection =
  resolveFeatures(cfg, opts.features, opts.allFeatures, opts.noDefaultFeatures)

proc resultJson*(node: JsonNode): OperationResult =
  ## Wrap a JSON node in a successful operation result.
  OperationResult(ok: true, json: node, output: $node)

proc errorJson(message: string): OperationResult =
  OperationResult(ok: false, json: %*{"error": message}, output: message)

proc loadProject(projectDir: string): WorkspaceProject =
  let cfg = loadEffectiveConfig(projectDir)
  WorkspaceProject(path: ".", projectDir: projectDir,
    name: cfg.package.name,
    cfg: cfg)

proc buildOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Build the default project target.
  let project = loadProject(projectDir)
  let selection = featureSelection(opts, project.cfg)
  let binary = buildSingleTarget(project.cfg, opts.profile, project.projectDir,
    opts.verbose, selection)
  resultJson(%*{"binary": binary, "profile": opts.profile})

proc runOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Build and run the default project target.
  let project = loadProject(projectDir)
  let selection = featureSelection(opts, project.cfg)
  runTarget(project.cfg, -1, opts.profile, project.projectDir, opts.runArgs,
    opts.verbose, selection)
  resultJson(%*{"status": "completed", "profile": opts.profile})

proc testOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Compile and run project tests, returning counts and failures.
  let project = loadProject(projectDir)
  let cfg = project.cfg
  let selection = featureSelection(opts, cfg)
  let profName = if cfg.profiles.hasKey("test"): "test" else: opts.profile
  let prof = if cfg.profiles.hasKey(profName):
               resolveProfile(cfg.profiles, profName)
             else:
               initProfileInfo()
  let testDir = project.projectDir / "tests"
  if not dirExists(testDir):
    return resultJson(%*{"passed": 0, "failed": 0, "total": 0,
      "failures": [], "message": "no tests directory"})
  var testFiles: seq[string]
  let runner = testDir / "tester.nim"
  if fileExists(runner) and opts.filter.len == 0:
    testFiles.add(runner)
  else:
    for file in walkFiles(testDir / "t*.nim"):
      let name = file.extractFilename
      if "thelper" notin name and (opts.filter.len == 0 or opts.filter in name):
        testFiles.add(file)
  testFiles.sort()
  let outDir = absolutePath(project.projectDir) / BuildDirName / profName
  let flags = collectCompilerFlags(prof, bkTest, outDir, cfg.build.source,
    project.projectDir, cfg, selection)
  var passed = 0
  var failed = 0
  var failures = newJArray()
  for file in testFiles:
    var args = @["c", "-r"]
    args.add(flags)
    args.add(file)
    let (exitCode, output) = runCmd(detectNimCompiler(), args,
      project.projectDir)
    if exitCode == 0:
      inc passed
    else:
      inc failed
      failures.add(%*{"file": file.extractFilename, "output": output})
  OperationResult(ok: failed == 0, json: %*{"passed": passed,
    "failed": failed, "total": testFiles.len, "failures": failures})

proc checkOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Run `nim check` against configured main files.
  let project = loadProject(projectDir)
  let cfg = project.cfg
  let selection = featureSelection(opts, cfg)
  let prof = if cfg.profiles.hasKey(opts.profile):
               resolveProfile(cfg.profiles, opts.profile)
             else:
               initProfileInfo()
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let outDir = absolutePath(project.projectDir) / BuildDirName / opts.profile
  let flags = collectCompilerFlags(prof, cfg.build.kind, outDir, sourceDir,
    project.projectDir, cfg, selection)
  var mains: seq[string]
  if cfg.build.main.len > 0:
    mains.add(cfg.build.main)
  for target in cfg.targets:
    if target.main.len > 0 and target.main notin mains:
      mains.add(target.main)
  if mains.len == 0:
    return errorJson("no main files configured")
  var results = newJArray()
  var ok = true
  for mainFile in mains:
    var args = @["check"]
    args.add(flags)
    args.add(mainFile)
    let (exitCode, output) = runCmd(detectNimCompiler(), args,
      project.projectDir)
    if exitCode != 0:
      ok = false
    results.add(%*{"file": mainFile, "exitCode": exitCode, "output": output})
  OperationResult(ok: ok, json: %*{"ok": ok, "checks": results})

proc docOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Build API documentation for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  var members = newJArray()
  var ok = true
  var combinedOutput = ""

  for project in projects:
    let docOpts = DocBuildOptions(
      profile: opts.profile,
      features: featureSelection(opts, project.cfg),
      verbose: opts.verbose,
      outDir: opts.docOutDir,
      entrypoints: opts.docEntrypoints,
      skipExamples: opts.docSkipExamples,
      includePrivate: opts.docIncludePrivate,
      noIndex: opts.docNoIndex)
    try:
      let report = buildApiDocs(project.cfg, project.projectDir, docOpts)
      if not report.ok:
        ok = false
      for command in report.commands:
        if command.output.len > 0:
          combinedOutput.add(command.output)
      let node = docReportJson(report)
      if projects.len == 1 and projects[0].path == ".":
        return OperationResult(ok: report.ok, json: node,
          output: combinedOutput)
      members.add(%*{"path": project.path, "name": project.name, "docs": node})
    except CatchableError as e:
      ok = false
      let node = %*{"ok": false, "error": e.msg, "outDir": ""}
      if projects.len == 1 and projects[0].path == ".":
        return OperationResult(ok: false, json: node, output: e.msg)
      members.add(%*{"path": project.path, "name": project.name, "docs": node})

  OperationResult(ok: ok, json: %*{"workspace": true, "root": projectDir,
    "kind": "apiDocs", "members": members}, output: combinedOutput)

proc cleanOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Remove the project's build directory.
  let buildDir = projectDir / BuildDirName
  if dirExists(buildDir):
    removeDir(buildDir)
  resultJson(%*{"status": "cleaned", "path": buildDir})

proc parseInstallAction(action: string): InstallAction =
  case action
  of "", "install":
    iaInstall
  of "update":
    iaUpdate
  of "remove", "uninstall":
    iaRemove
  else:
    raise newException(ValueError, "unknown install action: " & action)

proc installStatus(action: InstallAction; dryRun: bool): string =
  if dryRun:
    return "planned"
  case action
  of iaInstall:
    "installed"
  of iaUpdate:
    "updated"
  of iaRemove:
    "removed"

proc installResultNode(item: InstallResult): JsonNode =
  %*{
    "action": $item.action,
    "target": item.target,
    "profile": item.profile,
    "source": item.source,
    "destination": item.destination,
    "installDir": item.installDir,
    "changed": item.changed,
    "dryRun": item.dryRun
  }

proc installOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Install, update, or remove built binary targets.
  let project = loadProject(projectDir)
  let selection = featureSelection(opts, project.cfg)
  try:
    let action = parseInstallAction(opts.installAction)
    let results = installTargets(project.cfg, project.projectDir, opts.profile,
      opts.targetName, opts.installDir, action, opts.allTargets, opts.force,
      opts.dryRun, opts.verbose, selection)
    var targets = newJArray()
    for item in results:
      targets.add(installResultNode(item))
    resultJson(%*{
      "status": installStatus(action, opts.dryRun),
      "action": $action,
      "installDir": resolveInstallDir(project.cfg, project.projectDir,
        opts.installDir),
      "targets": targets
    })
  except CatchableError as e:
    errorJson(e.msg)

proc checkoutPrecise(projectDir, depName, precise: string): OperationResult =
  if precise.len == 0:
    return resultJson(%*{"status": "skipped"})
  if depName.len == 0:
    return errorJson("deps update --precise requires a package name")
  let depPath = projectDir / "deps" / depName
  if not dirExists(depPath / ".git"):
    return errorJson("deps update --precise currently requires a materialized git dependency: " &
      depName)
  let (exitCode, output) = runCmd("git", ["-C", depPath, "checkout", precise])
  if exitCode != 0:
    return errorJson(output)
  resultJson(%*{"status": "checked-out", "dependency": depName,
    "precise": precise})

proc depsOperation*(projectDir: string; opts: OperationOptions): OperationResult =
  ## Sync or update dependencies, then refresh `bau.lock`.
  let project = loadProject(projectDir)
  if opts.update:
    updateDeps(project.projectDir, opts.filter, verbose = opts.verbose)
    let precise = checkoutPrecise(project.projectDir, opts.filter, opts.precise)
    if not precise.ok:
      return precise
    let refreshed = loadEffectiveConfig(project.projectDir)
    let lockFile = generateLockFile(refreshed, project.projectDir)
    let unresolved = unresolvedLockEntries(refreshed, lockFile,
      project.projectDir)
    if unresolved.len > 0:
      return errorJson("dependency material missing after update: " &
        unresolved.join(", "))
    writeLockFile(lockFile, project.projectDir / LockFileName)
    return resultJson(%*{"status": "updated"})

  let selection = featureSelection(opts, project.cfg)
  syncDeps(project.cfg, project.projectDir, verbose = opts.verbose,
    featureSelection = selection)
  let lockFile = generateLockFile(project.cfg, project.projectDir)
  let unresolved = unresolvedLockEntries(project.cfg, lockFile,
    project.projectDir)
  if unresolved.len > 0:
    return errorJson("dependency material missing after sync: " &
      unresolved.join(", "))
  writeLockFile(lockFile, project.projectDir / LockFileName)
  resultJson(%*{"status": "synced"})

proc dependencyEdit(opts: OperationOptions): DependencyEdit =
  result = initDependencyEdit(opts.depName)
  result.version = opts.depVersion
  result.git = opts.depGit
  result.tag = opts.depTag
  result.branch = opts.depBranch
  result.rev = opts.depRev
  result.path = opts.depPath
  result.registry = opts.depRegistry
  result.optional = opts.depOptional

proc addDependencyOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
  ## Add a dependency to config, sync it, and refresh the lockfile.
  if opts.depName.len == 0:
    return errorJson("dependency name is required")
  try:
    addDependency(projectDir, dependencyEdit(opts))
  except CatchableError as e:
    return errorJson(e.msg)
  let cfg = loadEffectiveConfig(projectDir)
  syncDeps(cfg, projectDir, verbose = opts.verbose)
  let lockFile = generateLockFile(cfg, projectDir)
  let unresolved = unresolvedLockEntries(cfg, lockFile, projectDir)
  if unresolved.len > 0:
    return errorJson("dependency material missing after sync: " &
      unresolved.join(", "))
  writeLockFile(lockFile, projectDir / LockFileName)
  resultJson(%*{"status": "added", "name": opts.depName})

proc removeDependencyOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
  ## Remove a dependency from config and refresh the lockfile.
  if opts.depName.len == 0:
    return errorJson("dependency name is required")
  try:
    removeDependency(projectDir, opts.depName)
  except CatchableError as e:
    return errorJson(e.msg)
  let refreshed = loadEffectiveConfig(projectDir)
  writeLockFile(generateLockFile(refreshed, projectDir), projectDir / LockFileName)
  resultJson(%*{"status": "removed", "name": opts.depName})

proc initOperation*(projectDir: string; opts: OperationOptions): OperationResult =
  ## Initialize a new Bau project.
  let dir = if opts.initDir.len > 0: opts.initDir else: projectDir
  let kind = if opts.initKind.len > 0: opts.initKind else: "bin"
  if opts.initName.len == 0:
    return errorJson("package name is required")
  initProject(dir, opts.initName, kind)
  resultJson(%*{"status": "initialized", "name": opts.initName, "dir": dir})

proc convertOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
  ## Convert a Nimble project into Bau configuration.
  var baseDir = projectDir
  var nimblePath = ""
  if opts.convertPath.len > 0:
    if dirExists(opts.convertPath):
      baseDir = opts.convertPath
    else:
      nimblePath = opts.convertPath
      baseDir = parentDir(absolutePath(opts.convertPath))

  try:
    let conversion = convertNimbleProject(baseDir, nimblePath,
      write = not opts.dryRun, force = opts.force)
    var node = convertResultJson(conversion)
    if opts.dryRun:
      node["content"] = %conversion.content
    OperationResult(ok: true, json: node, output: $node)
  except CatchableError as e:
    errorJson(e.msg)

proc fmtOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Format Nim source files under `src` with `nimpretty`.
  let nimpretty = findExe("nimpretty")
  if nimpretty.len == 0:
    return errorJson("nimpretty not found")
  let sourceDir = projectDir / "src"
  if not dirExists(sourceDir):
    return resultJson(%*{"formatted": 0, "message": "no src directory"})
  var formatted = 0
  for file in walkDirRec(sourceDir, yieldFilter = {pcFile}):
    if file.endsWith(".nim"):
      runCmdLive(nimpretty, ["--backup:off", file])
      inc formatted
  resultJson(%*{"formatted": formatted})

proc fingerprintNode(fp: Fingerprint): JsonNode =
  parseJson(toJson(fp))

proc comparisonNode(cached, fresh: string): JsonNode =
  %*{
    "cached": cached,
    "fresh": fresh,
    "unchanged": cached == fresh
  }

proc fingerprintComparison(cached, fresh: Fingerprint): JsonNode =
  %*{
    "source": comparisonNode(cached.sourceHash, fresh.sourceHash),
    "flags": comparisonNode(cached.flagsHash, fresh.flagsHash),
    "config": comparisonNode(cached.configHash, fresh.configHash),
    "env": comparisonNode(cached.envHash, fresh.envHash),
    "compiler": comparisonNode(cached.compilerHash, fresh.compilerHash),
    "profile": comparisonNode(cached.profile, fresh.profile),
    "platform": comparisonNode(cached.platform, fresh.platform),
    "toolchain": comparisonNode(cached.toolchain, fresh.toolchain),
    "mtime": comparisonNode(cached.mtimeHash, fresh.mtimeHash)
  }

proc relativeFiles(projectDir: string; files: openArray[string]): seq[string] =
  for file in files:
    let rel = relativePath(file, projectDir).replace("\\", "/")
    if rel.len > 0 and not rel.startsWith(".."):
      result.add(rel)
    else:
      result.add(file.replace("\\", "/"))
  result.sort()

proc filesNewerThanOutput(projectDir, outputPath: string;
    files: openArray[string]): seq[string] =
  if not fileExists(outputPath):
    return
  let builtAt = getLastModificationTime(outputPath)
  for file in files:
    if fileExists(file) and getLastModificationTime(file) > builtAt:
      result.add(relativePath(file, projectDir).replace("\\", "/"))
  result.sort()

proc explainBuildNode(project: WorkspaceProject;
    opts: OperationOptions): JsonNode =
  let selection = featureSelection(opts, project.cfg)
  let ctx = initBuildContext(project.cfg, opts.profile, project.projectDir,
    opts.verbose, selection)
  let plan = resolveTargetPlan(ctx, -1)
  let fpDir = absolutePath(project.projectDir) / BuildDirName / FingerprintDirName
  let fpPath = fpDir / plan.outputName / "main.fp"
  let saved = loadFingerprint(fpDir, plan.outputName, "main")
  let inputs = initFingerprintInputs(plan.sourceFiles, plan.compilerFlags,
    plan.profile, collectFingerprintConfigInputs(project.projectDir),
    collectFingerprintEnvInputs())
  let fresh = computeFingerprint(inputs)

  result = %*{
    "target": plan.outputName,
    "profile": plan.profile,
    "fingerprintPath": fpPath,
    "binary": plan.binaryPath,
    "outputExists": fileExists(plan.binaryPath),
    "cached": saved.isSome,
    "sourceFiles": relativeFiles(project.projectDir, plan.sourceFiles),
    "compilerFlags": plan.compilerFlags,
    "freshFingerprint": fingerprintNode(fresh)
  }

  if saved.isSome:
    let cached = saved.get()
    let unchanged = cached == fresh
    result["fingerprint"] = fingerprintNode(cached)
    result["comparison"] = fingerprintComparison(cached, fresh)
    result["changed"] = %not unchanged
    result["wouldSkip"] = %(unchanged and fileExists(plan.binaryPath))
    result["changedFilesNewerThanOutput"] = %filesNewerThanOutput(
      project.projectDir, plan.binaryPath, plan.sourceFiles)
  else:
    result["changed"] = %true
    result["wouldSkip"] = %false
    result["message"] = %"no cached fingerprint; build has not run for this target/profile"

proc workspaceNode(root: string; kind: string; members: JsonNode): JsonNode
proc singleProject(projects: openArray[WorkspaceProject]): bool

proc explainOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Explain build fingerprint state for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(explainBuildNode(projects[0], opts))

  var members = newJArray()
  for project in projects:
    members.add(%*{
      "path": project.path,
      "name": project.name,
      "explain": explainBuildNode(project, opts)
    })
  resultJson(workspaceNode(projectDir, "explain", members))

proc workspaceNode(root: string; kind: string; members: JsonNode): JsonNode =
  %*{
    "workspace": true,
    "root": root,
    "kind": kind,
    "members": members
  }

proc resolvedLockSummary(projectDir: string): JsonNode =
  result = newJObject()
  if not fileExists(projectDir / LockFileName):
    return result
  try:
    let lockFile = parseLockFile(projectDir / LockFileName)
    var packages = newJArray()
    for key, pkg in lockFile.packages.pairs:
      var deps = newJArray()
      for edge in pkg.dependencies:
        deps.add(%edge.name)
      packages.add(%*{"id": key, "name": pkg.id.name,
        "version": pkg.id.version, "source": pkg.id.source,
        "direct": pkg.direct, "dependencies": deps})
    result = %*{"version": lockFile.version, "resolver": lockFile.resolver,
      "requirementsHash": lockFile.requirementsHash,
      "workspaceMembers": lockFile.workspaceMembers,
      "packages": packages}
  except CatchableError as e:
    result = %*{"error": e.msg}

proc singleProject(projects: openArray[WorkspaceProject]): bool =
  projects.len == 1 and projects[0].path == "."

proc metadataOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return effective configuration metadata for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(configMetadataJson(projects[0].cfg, projects[
        0].projectDir,
      opts.formatVersion))

  var members = newJArray()
  for project in projects:
    members.add(%*{
      "path": project.path,
      "name": project.name,
      "metadata": configMetadataJson(project.cfg, project.projectDir,
        opts.formatVersion)
    })
  var node = workspaceNode(projectDir, "metadata", members)
  node["lock"] = resolvedLockSummary(projectDir)
  resultJson(node)

proc graphOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return project or workspace graph data.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(graphJson(projects[0].cfg, projects[0].projectDir))

  var members = newJArray()
  for project in projects:
    members.add(%*{
      "path": project.path,
      "name": project.name,
      "graph": graphJson(project.cfg, project.projectDir)
    })
  var node = workspaceNode(projectDir, "graph", members)
  node["resolvedDependencies"] = resolvedLockSummary(projectDir)
  resultJson(node)

proc queryOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
  ## Run dependency and explanation queries.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    case opts.queryKind
    of "deps":
      let resolved = queryResolvedDeps(projects[0].projectDir, opts.queryName)
      if resolved.len > 0:
        return resultJson(%resolved)
      return resultJson(%queryDeps(projects[0].cfg, opts.queryName))
    of "why":
      let resolvedWhy = queryResolvedWhy(projects[0].projectDir, opts.queryName)
      if resolvedWhy.len > 0:
        return resultJson(%*{"dependency": opts.queryName,
          "why": resolvedWhy})
      return resultJson(%*{"dependency": opts.queryName,
        "why": queryWhy(projects[0].cfg, opts.queryName)})
    else:
      return OperationResult(ok: false, json: %*{"error": "unknown query"})

  var members = newJArray()
  for project in projects:
    case opts.queryKind
    of "deps":
      var resolved = queryResolvedDeps(project.projectDir, opts.queryName)
      if resolved.len == 0:
        resolved = queryResolvedDeps(projectDir, opts.queryName)
      let deps = if resolved.len > 0: resolved else:
                   queryDeps(project.cfg, opts.queryName)
      members.add(%*{"path": project.path, "name": project.name,
        "deps": deps})
    of "why":
      var resolvedWhy = queryResolvedWhy(project.projectDir, opts.queryName)
      if resolvedWhy.len == 0:
        resolvedWhy = queryResolvedWhy(projectDir, opts.queryName)
      let why = if resolvedWhy.len > 0: resolvedWhy else:
                  queryWhy(project.cfg, opts.queryName)
      members.add(%*{"path": project.path, "name": project.name,
        "why": why})
    else:
      return OperationResult(ok: false, json: %*{"error": "unknown query"})
  resultJson(workspaceNode(projectDir, "query", members))

proc relativeMemberChanges(root: string; project: WorkspaceProject;
    changed: openArray[string]): seq[string] =
  if project.path == ".":
    for file in changed:
      result.add(file)
    return
  let prefix = project.path.replace("\\", "/").strip(chars = {'/'}) & "/"
  for file in changed:
    let clean = file.replace("\\", "/")
    if clean.startsWith(prefix):
      result.add(clean[prefix.len..^1])

proc affectedJson(report: AffectedReport): JsonNode =
  %*{
    "changedFiles": report.changedFiles,
    "sourceFiles": report.sourceFiles,
    "targets": report.targets,
    "tests": report.tests,
    "tasks": report.tasks
  }

proc affectedOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return affected targets, tests, tasks, and source files.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(affectedJson(computeAffected(projects[0].cfg,
      projects[0].projectDir, opts.since)))

  let rootChanges = gitChangedFiles(projectDir, opts.since)
  var members = newJArray()
  for project in projects:
    let report = computeAffectedFromChanges(project.cfg, project.projectDir,
      relativeMemberChanges(projectDir, project, rootChanges))
    members.add(%*{"path": project.path, "name": project.name,
      "affected": affectedJson(report)})
  resultJson(workspaceNode(projectDir, "affected", members))

proc depsVerifyOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Validate dependency policy and lockfile health.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    let check = checkDependencyPolicy(projects[0].cfg, projects[0].projectDir)
    return OperationResult(ok: check.ok, json: %*{"ok": check.ok,
      "messages": check.messages})

  var ok = true
  var members = newJArray()
  for project in projects:
    let check = checkDependencyPolicy(project.cfg, project.projectDir)
    if not check.ok:
      ok = false
    members.add(%*{"path": project.path, "name": project.name,
      "ok": check.ok, "messages": check.messages})
  OperationResult(ok: ok, json: workspaceNode(projectDir, "depsVerify", members))

proc findTask(cfg: BauConfig; name: string): Option[TaskInfo] =
  for task in cfg.tasks:
    if task.name == name:
      return some(task)
  none(TaskInfo)

proc cacheExplainNode(task: TaskInfo; project: WorkspaceProject;
    opts: OperationOptions): JsonNode =
  let selection = featureSelection(opts, project.cfg)
  let report = explainTaskCache(task, project.projectDir, project.cfg,
    opts.profile, selection)
  %*{
    "task": report.task,
    "key": report.key,
    "path": report.path,
    "hit": report.localHit or report.remoteHit,
    "localHit": report.localHit,
    "remoteHit": report.remoteHit,
    "remoteError": report.remoteError,
    "keyInputs": report.keyInputs,
    "outputs": report.outputs
  }

proc cacheExplainOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
  ## Explain local and remote task-cache lookup state for one task.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    let task = findTask(projects[0].cfg, opts.taskName)
    if task.isNone:
      return OperationResult(ok: false, json: %*{"error": "task not found: " &
        opts.taskName})
    return resultJson(cacheExplainNode(task.get(), projects[0], opts))

  var members = newJArray()
  var found = false
  for project in projects:
    let task = findTask(project.cfg, opts.taskName)
    if task.isSome:
      found = true
      members.add(%*{"path": project.path, "name": project.name,
        "cache": cacheExplainNode(task.get(), project, opts)})
  if not found:
    return OperationResult(ok: false, json: %*{"error": "task not found: " &
      opts.taskName})
  resultJson(workspaceNode(projectDir, "cacheExplain", members))

proc addCompileEntry(entries: var seq[JsonNode]; projectDir, file: string;
    flags: openArray[string]; outDir: string) =
  var entry = newJObject()
  entry["directory"] = %projectDir
  entry["file"] = %absolutePath(file)
  var args = newJArray()
  args.add %detectNimCompiler()
  args.add %"check"
  for fl in flags:
    args.add %fl
  args.add %("--out:" & (outDir / splitFile(file).name))
  args.add %file
  entry["arguments"] = args
  entries.add(entry)

proc compileCommandEntries*(projectDir: string; cfg: BauConfig; profile: string;
    selection: FeatureSelection): seq[JsonNode] =
  ## Build compile command entries for source and test Nim files.
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  var prof = initProfileInfo()
  if profile.len > 0 and cfg.profiles.hasKey(profile):
    prof = resolveProfile(cfg.profiles, profile)
  let outDir = absolutePath(projectDir) / BuildDirName / profile
  let flags = collectCompilerFlags(prof, cfg.build.kind, outDir, sourceDir,
    projectDir, cfg, selection)

  var seen = initHashSet[string]()
  let absSource = projectDir / sourceDir
  if dirExists(absSource):
    for f in walkDirRec(absSource, yieldFilter = {pcFile}):
      if f.endsWith(".nim") and not seen.contains(f):
        seen.incl(f)
        result.addCompileEntry(projectDir, f, flags, outDir)
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    let testFlags = collectCompilerFlags(prof, bkTest, outDir, sourceDir,
      projectDir, cfg, selection)
    for f in walkDirRec(testDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim") and not seen.contains(f):
        seen.incl(f)
        result.addCompileEntry(projectDir, f, testFlags, outDir)

proc toJson(compiled: CompileCommandsResult): JsonNode =
  var members = newJArray()
  for member in compiled.members:
    members.add(%*{
      "path": member.path,
      "name": member.name,
      "entries": member.entries
    })
  if compiled.workspace:
    %*{
      "workspace": true,
      "root": compiled.root,
      "kind": "compileCommands",
      "members": members
    }
  else:
    %*{"entries": compiled.entries, "path": compiled.path}

proc compileCommandsOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Write `compile_commands.json` for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  var allEntries = newJArray()
  var compiled = CompileCommandsResult(
    workspace: not singleProject(projects),
    root: projectDir)
  for project in projects:
    let selection = featureSelection(opts, project.cfg)
    let entries = compileCommandEntries(project.projectDir, project.cfg,
      opts.profile, selection)
    saveFile(project.projectDir / "compile_commands.json", pretty(%entries))
    for entry in entries:
      allEntries.add(entry)
    compiled.members.add(CompileCommandsMemberResult(path: project.path,
      name: project.name, entries: entries.len))
  if not singleProject(projects):
    saveFile(projectDir / "compile_commands.json", pretty(allEntries))
    return resultJson(compiled.toJson())
  compiled.entries = allEntries.len
  compiled.path = projects[0].projectDir / "compile_commands.json"
  resultJson(compiled.toJson())
