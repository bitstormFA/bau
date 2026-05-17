## Exposes Bau operations behind CLI and MCP entry points.

import std/[algorithm, json, options, os, sets, strutils, tables, times]
import bau/[affected, atlas, build, config, depscheck, features, fingerprint,
  init, lock, metadata, nimble, taskcache, util, workspace, configedit, docgen,
  installer, ci_templates, packaging, tailor, taskgraph, testexec, toolchain,
  agentsetup]

type
  OperationOptions* = object     ## Shared options accepted by CLI and MCP operations.
    profile*: string             ## Build or documentation profile.
    features*: seq[string]       ## Explicit feature names requested by the caller.
    allFeatures*: bool           ## Enable every non-default feature.
    noDefaultFeatures*: bool     ## Skip the default feature.
    since*: string               ## Git revision or ref for affected analysis.
    taskName*: string            ## Task name for task-oriented operations.
    queryKind*: string           ## Query mode such as `deps` or `why`.
    queryName*: string           ## Target, task, feature, or dependency being queried.
    runArgs*: seq[string]        ## Arguments passed through to `run`.
    filter*: string              ## Optional dependency or test filter.
    precise*: string             ## Exact dependency revision for update operations.
    verbose*: bool               ## Whether nested commands should print details.
    allTargets*: bool            ## Select all eligible targets.
    update*: bool                ## Request dependency update rather than sync.
    force*: bool                 ## Allow overwriting or bypass cached state.
    dryRun*: bool                ## Plan the operation without writing when supported.
    targetName*: string          ## Explicit build or install target name.
    installAction*: string       ## Install action text such as `install` or `remove`.
    installDir*: string          ## Installation directory override.
    depName*: string             ## Dependency name for add/remove operations.
    depVersion*: string          ## Dependency version requirement.
    depGit*: string              ## Dependency Git URL.
    depTag*: string              ## Dependency Git tag.
    depBranch*: string           ## Dependency Git branch.
    depRev*: string              ## Dependency exact Git revision.
    depPath*: string             ## Dependency local path.
    depRegistry*: string         ## Dependency registry source.
    depOptional*: bool           ## Whether the dependency is optional.
    initName*: string            ## Package name for project initialization.
    initKind*: string            ## Project kind for initialization.
    initDir*: string             ## Directory for project initialization.
    convertPath*: string         ## Nimble file or directory to convert.
    formatVersion*: int          ## Metadata JSON format version.
    docOutDir*: string           ## Documentation output directory override.
    docEntrypoints*: seq[string] ## Additional documentation entrypoints.
    docSkipExamples*: bool       ## Skip compiling runnable examples during docs.
    docIncludePrivate*: bool     ## Include private symbols in docs.
    docNoIndex*: bool            ## Suppress generated docs index.
    depsAction*: string          ## Dependency action such as `sync`, `lock`, or `vendor`.
    cacheAction*: string         ## Task cache action such as `list`, `clean`, or `explain`.
    affectedAction*: string ## Affected action such as `list`, `check`, `test`, or `build`.
    list*: bool                  ## Request list output for operations that support it.
    write*: bool                 ## Write discovered changes when supported.
    keepGoing*: bool             ## Continue independent task dependencies after failures.
    taskArgs*: seq[string]       ## Arguments passed to the root task.
    offline*: bool               ## Avoid network dependency operations.
    locked*: bool                ## Require an up-to-date lockfile before dependency work.
    bumpKind*: string            ## Version component to bump.
    ciKind*: string              ## CI template kind such as `github` or `gitlab`.
    shellName*: string           ## Shell name for shell initialization.
    testChanged*: bool           ## Limit tests to changed files.
    testFull*: bool              ## Run the full configured test matrix.
    testFast*: bool              ## Run the fast local test mode.
    testNoMatrix*: bool          ## Run one test profile instead of the matrix.
    testNoRunner*: bool          ## Discover test files instead of using a runner.
    testShowOutput*: string      ## Test output mode override.
    jobs*: int                   ## Maximum parallel jobs for operations that support it.
    jobsExplicit*: bool          ## True when jobs was provided explicitly.
    agentTargets*: seq[string]   ## Agent hosts to configure for MCP setup.

  CompileCommandsMemberResult* = object ## Per-member compile commands summary.
    path*: string                       ## Workspace member path.
    name*: string                       ## Workspace member package name.
    entries*: int                       ## Number of compile command entries written.

  CompileCommandsResult* = object              ## Result of generating compile commands.
    workspace*: bool ## True when multiple workspace members were processed.
    root*: string                              ## Workspace or project root.
    path*: string                              ## Single-project compile commands path.
    entries*: int                              ## Single-project entry count.
    members*: seq[CompileCommandsMemberResult] ## Workspace member summaries.

  OperationResult* = object ## Standard result returned by operation APIs.
    ok*: bool               ## True when the operation succeeded.
    json*: JsonNode         ## Machine-readable result payload.
    output*: string         ## Human-readable or compiler output.

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

proc workspaceNode(root: string; kind: string; members: JsonNode): JsonNode
proc singleProject(projects: openArray[WorkspaceProject]): bool
proc depsVerifyOperation*(projectDir: string;
    opts: OperationOptions): OperationResult

proc buildOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Build project targets.
  let projects = loadWorkspaceProjects(projectDir)
  var targets = newJArray()
  for project in projects:
    let selection = featureSelection(opts, project.cfg)
    if opts.targetName.len > 0:
      let binary = buildTargetByName(project.cfg, opts.targetName, opts.profile,
        project.projectDir, opts.verbose, selection)
      targets.add(%*{"path": project.path, "name": project.name,
        "target": opts.targetName, "binary": binary})
    elif opts.allTargets:
      buildAllTargets(project.cfg, opts.profile, project.projectDir,
        opts.verbose, selection)
      targets.add(%*{"path": project.path, "name": project.name,
        "allTargets": true})
    else:
      let binary = buildSingleTarget(project.cfg, opts.profile,
        project.projectDir, opts.verbose, selection)
      targets.add(%*{"path": project.path, "name": project.name,
        "target": defaultTargetName(project.cfg), "binary": binary})
  if singleProject(projects):
    return resultJson(targets[0])
  resultJson(workspaceNode(projectDir, "build", targets))

proc runOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Build and run a project target.
  let project = loadProject(projectDir)
  let selection = featureSelection(opts, project.cfg)
  if opts.targetName.len > 0:
    runTargetByName(project.cfg, opts.targetName, opts.profile,
      project.projectDir, opts.runArgs, opts.verbose, selection)
  else:
    runTarget(project.cfg, -1, opts.profile, project.projectDir, opts.runArgs,
      opts.verbose, selection)
  resultJson(%*{"status": "completed", "profile": opts.profile,
    "target": if opts.targetName.len > 0: opts.targetName else:
      defaultTargetName(project.cfg)})

proc testOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Compile and run project tests, returning aggregate counts.
  let project = loadProject(projectDir)
  let cfg = project.cfg
  let selection = featureSelection(opts, cfg)
  if not dirExists(project.projectDir / "tests") and cfg.test.runner.len == 0:
    return resultJson(%*{"planned": 0, "passed": 0, "failed": 0,
      "message": "no tests directory"})
  let testResult = runTests(cfg, project.projectDir, TestRunOptions(
    profile: opts.profile,
    profileExplicit: false,
    filter: opts.filter,
    changed: opts.testChanged,
    since: opts.since,
    passthroughArgs: opts.runArgs,
    showOutput: effectiveTestOutputMode(cfg, opts.testShowOutput),
    verbose: opts.verbose,
    dryRun: opts.dryRun,
    jobs: opts.jobs,
    jobsExplicit: opts.jobsExplicit,
    noMatrix: opts.testNoMatrix,
    full: opts.testFull,
    fast: opts.testFast,
    noRunner: opts.testNoRunner,
    featureSelection: selection))
  OperationResult(ok: opts.dryRun or testResult.failed == 0,
    json: %*{"planned": testResult.planned, "passed": testResult.passed,
      "failed": testResult.failed})

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
  if opts.allTargets:
    if cfg.build.main.len > 0:
      mains.add(cfg.build.main)
    for target in cfg.targets:
      if target.main.len > 0 and target.main notin mains:
        mains.add(target.main)
  elif opts.targetName.len > 0:
    let idx = findTargetIndex(cfg, opts.targetName)
    if idx >= 0:
      mains.add(cfg.targets[idx].main)
    elif opts.targetName == defaultTargetName(cfg):
      mains.add(cfg.build.main)
    else:
      return errorJson("target not found: " & opts.targetName)
  elif cfg.build.main.len > 0:
    mains.add(cfg.build.main)
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

proc toLockProjects(projects: openArray[WorkspaceProject]): seq[LockProject] =
  for project in projects:
    result.add(LockProject(path: project.path, projectDir: project.projectDir,
      cfg: project.cfg))

proc unresolvedForProjects(projects: openArray[WorkspaceProject];
    lockFile: LockFile): seq[string] =
  for project in projects:
    for name in unresolvedLockEntries(project.cfg, lockFile,
        project.projectDir):
      result.add(project.path & ":" & name)
  result.sort()

proc dependencyCheckNode(check: DependencyCheck): JsonNode =
  %*{"ok": check.ok, "messages": check.messages}

proc dependencyCheckNode(report: LockValidationReport): JsonNode =
  var diagnostics = newJArray()
  for item in report.diagnostics:
    diagnostics.add(%*{"kind": $item.kind, "packageName": item.packageName,
      "path": item.path, "message": item.message})
  %*{"ok": report.ok, "messages": report.messages,
    "diagnostics": diagnostics}

proc dependencyCheckNode(check: ToolchainCheck): JsonNode =
  %*{"ok": check.ok, "messages": check.messages}

proc vendorDependencies(projectDir: string): JsonNode =
  let depsDir = projectDir / "deps"
  if not dirExists(depsDir):
    raise newException(IOError, "no deps/ directory found; run deps sync first")
  let vendorDir = projectDir / "vendor"
  if dirExists(vendorDir):
    removeDir(vendorDir)
  copyDir(depsDir, vendorDir)
  var manifest = "# bau vendor checksums\n"
  var packages = newJArray()
  for kind, path in walkDir(vendorDir):
    if kind == pcDir:
      let name = path.extractFilename
      let checksum = checksumPath(path)
      manifest.add(name & " = " & toTomlString(checksum) & "\n")
      packages.add(%*{"name": name, "checksum": checksum})
  saveFile(vendorDir / ".bau-vendor-checksums", manifest)
  %*{"vendorDir": vendorDir, "packages": packages}

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
  ## Run dependency sync, lock, update, verify, vendor, or patch operations.
  var action = opts.depsAction
  if action.len == 0:
    action = if opts.update: "update" else: "sync"
  let depFilter = if opts.filter.len > 0: opts.filter else: opts.depName

  try:
    if isWorkspaceRoot(projectDir) and action in ["lock", "sync", "update",
        "verify", "vendor"]:
      let projects = loadWorkspaceProjects(projectDir)
      let lockProjects = toLockProjects(projects)
      let lockPath = projectDir / LockFileName
      if opts.locked:
        let report = validateLockFile(lockProjects, projectDir, lockPath)
        if not report.ok:
          return OperationResult(ok: false, json: dependencyCheckNode(report))

      case action
      of "lock":
        let lockFile = generateLockFile(lockProjects, projectDir)
        let unresolved = unresolvedForProjects(projects, lockFile)
        if unresolved.len > 0:
          return errorJson("cannot write reproducible " & LockFileName &
            "; dependency material is missing for " & unresolved.join(", "))
        writeLockFile(lockFile, lockPath)
        return resultJson(%*{"status": "locked", "workspace": true,
          "path": lockPath})
      of "sync":
        var selections: seq[FeatureSelection]
        for project in projects:
          selections.add(featureSelection(opts, project.cfg))
        if opts.offline:
          let check = checkOfflineDependencies(lockProjects, projectDir,
            lockPath, selections)
          return OperationResult(ok: check.ok, json: dependencyCheckNode(check))
        for i, project in projects:
          syncDeps(project.cfg, project.projectDir, verbose = opts.verbose,
            featureSelection = selections[i])
        let lockFile = generateLockFile(lockProjects, projectDir)
        let unresolved = unresolvedForProjects(projects, lockFile)
        if unresolved.len > 0:
          return errorJson("dependency material missing after sync: " &
            unresolved.join(", "))
        writeLockFile(lockFile, lockPath)
        return resultJson(%*{"status": "synced", "workspace": true,
          "path": lockPath})
      of "update":
        if opts.offline:
          return errorJson("deps update cannot run with --offline")
        for project in projects:
          updateDeps(project.projectDir, depFilter, verbose = opts.verbose)
          let precise = checkoutPrecise(project.projectDir, depFilter,
            opts.precise)
          if not precise.ok:
            return precise
        let refreshed = loadWorkspaceProjects(projectDir)
        let refreshedLockProjects = toLockProjects(refreshed)
        let lockFile = generateLockFile(refreshedLockProjects, projectDir)
        let unresolved = unresolvedForProjects(refreshed, lockFile)
        if unresolved.len > 0:
          return errorJson("dependency material missing after update: " &
            unresolved.join(", "))
        writeLockFile(lockFile, lockPath)
        return resultJson(%*{"status": "updated", "workspace": true,
          "path": lockPath})
      of "verify":
        return depsVerifyOperation(projectDir, opts)
      of "vendor":
        var members = newJArray()
        for project in projects:
          members.add(%*{"path": project.path, "name": project.name,
            "vendor": vendorDependencies(project.projectDir)})
        return resultJson(workspaceNode(projectDir, "vendor", members))
      else:
        discard

    let project = loadProject(projectDir)
    if opts.locked:
      let report = validateLockFile(project.cfg, project.projectDir,
        project.projectDir / LockFileName)
      if not report.ok:
        return OperationResult(ok: false, json: dependencyCheckNode(report))

    case action
    of "lock":
      let lockFile = generateLockFile(project.cfg, project.projectDir)
      let unresolved = unresolvedLockEntries(project.cfg, lockFile,
        project.projectDir)
      if unresolved.len > 0:
        return errorJson("cannot write reproducible " & LockFileName &
          "; dependency material is missing for " & unresolved.join(", "))
      writeLockFile(lockFile, project.projectDir / LockFileName)
      resultJson(%*{"status": "locked", "path": project.projectDir / LockFileName})
    of "sync":
      let selection = featureSelection(opts, project.cfg)
      if opts.offline:
        let check = checkOfflineDependencies(project.cfg, project.projectDir,
          selection)
        return OperationResult(ok: check.ok, json: dependencyCheckNode(check))
      syncDeps(project.cfg, project.projectDir, verbose = opts.verbose,
        featureSelection = selection)
      let lockFile = generateLockFile(project.cfg, project.projectDir)
      let unresolved = unresolvedLockEntries(project.cfg, lockFile,
        project.projectDir)
      if unresolved.len > 0:
        return errorJson("dependency material missing after sync: " &
          unresolved.join(", "))
      writeLockFile(lockFile, project.projectDir / LockFileName)
      resultJson(%*{"status": "synced", "path": project.projectDir / LockFileName})
    of "update":
      if opts.offline:
        return errorJson("deps update cannot run with --offline")
      updateDeps(project.projectDir, depFilter, verbose = opts.verbose)
      let precise = checkoutPrecise(project.projectDir, depFilter,
        opts.precise)
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
      resultJson(%*{"status": "updated", "path": project.projectDir / LockFileName})
    of "verify":
      depsVerifyOperation(projectDir, opts)
    of "vendor":
      resultJson(%*{"status": "vendored", "vendor": vendorDependencies(
        project.projectDir)})
    of "patch":
      if opts.depName.len == 0 or opts.depPath.len == 0:
        return errorJson("deps patch requires dependency name and path")
      writePatchEntry(project.projectDir, opts.depName, opts.depPath)
      resultJson(%*{"status": "patched", "name": opts.depName,
        "path": opts.depPath})
    else:
      errorJson("unknown deps action: " & action)
  except CatchableError as e:
    errorJson(e.msg)

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

proc affectedCheckNode(project: WorkspaceProject; report: AffectedReport;
    opts: OperationOptions): JsonNode =
  let selection = featureSelection(opts, project.cfg)
  let prof = if project.cfg.profiles.hasKey(opts.profile):
               resolveProfile(project.cfg.profiles, opts.profile)
             else:
               initProfileInfo()
  let sourceDir = if project.cfg.build.source.len > 0:
                    project.cfg.build.source
                  else:
                    "src"
  let outDir = absolutePath(project.projectDir) / BuildDirName / opts.profile
  let flags = collectCompilerFlags(prof, project.cfg.build.kind, outDir,
    sourceDir, project.projectDir, project.cfg, selection)
  var checks = newJArray()
  var ok = true
  for target in report.targets:
    let idx = findTargetIndex(project.cfg, target)
    let mainFile = if idx >= 0: project.cfg.targets[idx].main else:
                     project.cfg.build.main
    var args = @["check"]
    args.add(flags)
    args.add(mainFile)
    let (exitCode, output) = runCmd(detectNimCompiler(), args,
      project.projectDir)
    if exitCode != 0:
      ok = false
    checks.add(%*{"target": target, "file": mainFile, "exitCode": exitCode,
      "output": output})
  %*{"ok": ok, "checks": checks}

proc affectedOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return or run affected targets, tests, tasks, and source files.
  let action = if opts.affectedAction.len > 0: opts.affectedAction else: "list"
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    let report = computeAffected(projects[0].cfg, projects[0].projectDir,
      opts.since)
    case action
    of "list":
      return resultJson(affectedJson(report))
    of "build":
      let selection = featureSelection(opts, projects[0].cfg)
      var built = newJArray()
      for target in report.targets:
        let binary = buildTargetByName(projects[0].cfg, target, opts.profile,
          projects[0].projectDir, opts.verbose, selection)
        built.add(%*{"target": target, "binary": binary})
      return resultJson(%*{"built": built})
    of "test":
      var testOpts = opts
      testOpts.testChanged = true
      return testOperation(projects[0].projectDir, testOpts)
    of "check":
      let node = affectedCheckNode(projects[0], report, opts)
      return OperationResult(ok: node["ok"].getBool(), json: node)
    else:
      return errorJson("unknown affected action: " & action)

  let rootChanges = gitChangedFiles(projectDir, opts.since)
  var members = newJArray()
  var ok = true
  for project in projects:
    let report = computeAffectedFromChanges(project.cfg, project.projectDir,
      relativeMemberChanges(projectDir, project, rootChanges))
    case action
    of "list":
      members.add(%*{"path": project.path, "name": project.name,
        "affected": affectedJson(report)})
    of "build":
      let selection = featureSelection(opts, project.cfg)
      var built = newJArray()
      for target in report.targets:
        let binary = buildTargetByName(project.cfg, target, opts.profile,
          project.projectDir, opts.verbose, selection)
        built.add(%*{"target": target, "binary": binary})
      members.add(%*{"path": project.path, "name": project.name,
        "built": built})
    of "test":
      var testOpts = opts
      testOpts.testChanged = true
      let tested = testOperation(project.projectDir, testOpts)
      if not tested.ok:
        ok = false
      members.add(%*{"path": project.path, "name": project.name,
        "test": tested.json})
    of "check":
      let checked = affectedCheckNode(project, report, opts)
      if not checked["ok"].getBool():
        ok = false
      members.add(%*{"path": project.path, "name": project.name,
        "check": checked})
    else:
      return errorJson("unknown affected action: " & action)
  OperationResult(ok: ok, json: workspaceNode(projectDir, "affected", members))

proc depsVerifyOperation*(projectDir: string;
    opts: OperationOptions): OperationResult =
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

proc lintOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Check Nim source style without rewriting files.
  let project = loadProject(projectDir)
  let sourceDir = if project.cfg.build.source.len > 0:
                    project.cfg.build.source
                  else:
                    "src"
  let absSource = absolutePath(project.projectDir) / sourceDir
  var files = newJArray()
  var issues = newJArray()
  if dirExists(absSource):
    var lintArgs = @["check", "--styleCheck:error", "--hints:off",
      "--path:" & absSource]
    let depsDir = project.projectDir / "deps"
    if dirExists(depsDir):
      for kind, path in walkDir(depsDir):
        if kind == pcDir:
          lintArgs.add("--path:" & path)
    for file in walkDirRec(absSource, yieldFilter = {pcFile}):
      if not file.endsWith(".nim"):
        continue
      var fileArgs = lintArgs
      fileArgs.add(file)
      let (exitCode, output) = runCmd(detectNimCompiler(), fileArgs)
      let rel = relativePath(file, project.projectDir).replace("\\", "/")
      files.add(%rel)
      if exitCode != 0:
        issues.add(%*{"file": rel, "exitCode": exitCode, "output": output})
  let ok = issues.len == 0
  OperationResult(ok: ok, json: %*{"ok": ok, "files": files,
    "issues": issues})

proc ciOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Run validation-oriented CI checks without rewriting source files.
  var checks = newJObject()
  let lint = lintOperation(projectDir, opts)
  checks["lint"] = lint.json
  if not lint.ok:
    return OperationResult(ok: false, json: %*{"ok": false, "checks": checks})

  var testOpts = opts
  testOpts.testFull = true
  let tests = testOperation(projectDir, testOpts)
  checks["test"] = tests.json
  OperationResult(ok: tests.ok, json: %*{"ok": tests.ok, "checks": checks})

proc taskInfoNode(task: TaskInfo): JsonNode =
  %*{
    "name": task.name,
    "cmd": task.cmd,
    "command": task.command,
    "description": task.description,
    "deps": task.deps,
    "inputs": task.inputs,
    "outputs": task.outputs,
    "cwd": if task.cwd.isSome: task.cwd.get() else: "",
    "shell": task.shell,
    "profile": task.profile,
    "envInputs": task.envInputs,
    "cache": task.cache,
    "acceptArgs": task.acceptArgs,
    "requiredFeatures": task.requiredFeatures,
    "tags": task.tags
  }

proc taskOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## List or run project tasks.
  let project = loadProject(projectDir)
  if opts.list:
    var tasks = newJArray()
    for task in project.cfg.tasks:
      tasks.add(taskInfoNode(task))
    return resultJson(%*{"tasks": tasks})
  if opts.taskName.len == 0:
    return errorJson("task name is required")
  let selection = featureSelection(opts, project.cfg)
  try:
    let ok = runTaskByName(project.cfg, opts.taskName, project.projectDir,
      TaskRunOptions(profile: opts.profile, verbose: opts.verbose,
        dryRun: opts.dryRun, force: opts.force, keepGoing: opts.keepGoing,
        features: selection, taskArgs: opts.taskArgs))
    OperationResult(ok: ok, json: %*{"ok": ok, "task": opts.taskName})
  except CatchableError as e:
    errorJson(e.msg)

proc cacheOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## List, clean, or explain task cache entries.
  let action = if opts.cacheAction.len > 0: opts.cacheAction else:
                 (if opts.taskName.len > 0: "explain" else: "list")
  let project = loadProject(projectDir)
  case action
  of "list":
    resultJson(%*{"entries": listTaskCacheEntries(project.projectDir,
      project.cfg)})
  of "clean":
    cleanTaskCache(project.projectDir, project.cfg)
    resultJson(%*{"status": "cleaned"})
  of "explain":
    cacheExplainOperation(projectDir, opts)
  else:
    errorJson("unknown cache action: " & action)

proc dependencyTreeOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return dependency tree data for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(dependencyTreeJson(projects[0].cfg, projects[0].projectDir))
  var members = newJArray()
  for project in projects:
    members.add(%*{"path": project.path, "name": project.name,
      "tree": dependencyTreeJson(project.cfg, project.projectDir)})
  resultJson(workspaceNode(projectDir, "dependencyTree", members))

proc dependencyStatusOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return dependency status data for a project or workspace.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    return resultJson(dependencyStatusJson(projects[0].cfg,
      projects[0].projectDir))
  var members = newJArray()
  for project in projects:
    members.add(%*{"path": project.path, "name": project.name,
      "status": dependencyStatusJson(project.cfg, project.projectDir)})
  resultJson(workspaceNode(projectDir, "dependencyStatus", members))

proc tailorOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Discover or write missing target declarations.
  let projects = loadWorkspaceProjects(projectDir)
  if singleProject(projects):
    let tailored = discoverTargets(projects[0].cfg, projects[0].projectDir)
    if opts.write:
      appendTailoredTargets(projects[0].projectDir, tailored)
    return OperationResult(ok: tailored.missingTargets.len == 0 or opts.write,
      json: tailorJson(tailored))

  var members = newJArray()
  var missing = 0
  for project in projects:
    let tailored = discoverTargets(project.cfg, project.projectDir)
    missing += tailored.missingTargets.len
    if opts.write:
      appendTailoredTargets(project.projectDir, tailored)
    members.add(%*{"path": project.path, "name": project.name,
      "tailor": tailorJson(tailored)})
  OperationResult(ok: missing == 0 or opts.write,
    json: %*{"workspace": true, "root": projectDir, "members": members,
      "ok": missing == 0})

proc packageOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Validate Package Contents and optionally write a package manifest output.
  try:
    let cfg = loadEffectiveConfig(projectDir)
    verifyPackage(projectDir, cfg)
    let files = collectPackageFiles(projectDir, cfg)
    var node = %*{"ok": true, "files": files}
    if opts.dryRun:
      node["status"] = %"validated"
      return resultJson(node)
    if opts.list:
      node["status"] = %"listed"
      return resultJson(node)
    let outDir = projectDir / BuildDirName / "package"
    let manifestPath = outDir / (cfg.package.name & "-" & cfg.package.version &
      ".manifest")
    saveFile(manifestPath, packageManifest(projectDir, cfg))
    node["status"] = %"generated"
    node["manifestPath"] = %manifestPath
    resultJson(node)
  except CatchableError as e:
    errorJson(e.msg)

proc publishOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Validate or submit a Package Publication.
  try:
    if not fileExists(projectDir / ConfigFileName):
      return errorJson("no bau.toml found")
    let cfg = parseBauConfigFile(projectDir / ConfigFileName)
    verifyPackage(projectDir, cfg)
    let files = collectPackageFiles(projectDir, cfg)
    let nimble = nimbleContent(cfg)
    if opts.dryRun:
      return resultJson(%*{"status": "validated", "dryRun": true,
        "files": files, "nimble": nimble})
    if hasLocalPublishOverrides(cfg):
      return errorJson("publish cannot use local path dependencies or [patch]")
    let nimbleCmd = findExe("nimble")
    if nimbleCmd.len == 0:
      return errorJson("nimble not found; install it to publish")
    let nimblePath = projectDir / (cfg.package.name & ".nimble")
    if not fileExists(nimblePath):
      saveFile(nimblePath, nimble)
    let (exitCode, output) = runCmd(nimbleCmd, ["publish"], projectDir)
    OperationResult(ok: exitCode == 0, json: %*{"status": "published",
      "exitCode": exitCode, "output": output}, output: output)
  except CatchableError as e:
    errorJson(e.msg)

proc bumpOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Increment Package version intent.
  if opts.bumpKind.len == 0:
    return errorJson("bump kind is required")
  try:
    let kind = parseVersionBumpKind(opts.bumpKind)
    let bumped = bumpPackageVersion(projectDir, kind, opts.dryRun)
    resultJson(%*{"oldVersion": bumped.oldVersion,
      "newVersion": bumped.newVersion, "nimblePath": bumped.nimblePath,
      "configChanged": bumped.configChanged,
      "nimbleChanged": bumped.nimbleChanged, "dryRun": opts.dryRun})
  except CatchableError as e:
    errorJson(e.msg)

proc ciTemplateOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Write a CI template file.
  let kind = if opts.ciKind.len > 0: opts.ciKind else: "github"
  if kind notin ["github", "gitlab"]:
    return errorJson("unknown CI kind: " & kind)
  generateCiTemplate(kind, projectDir)
  let path = if kind == "github":
               projectDir / ".github" / "workflows" / "ci.yml"
             else:
               projectDir / ".gitlab-ci.yml"
  resultJson(%*{"status": "generated", "kind": kind, "path": path})

proc envOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Return the resolved Build Environment summary.
  let root = try: findProjectRoot(projectDir) except CatchableError: projectDir
  let cfg = try: loadEffectiveConfig(root) except CatchableError: initBauConfig()
  let selection = featureSelection(opts, cfg)
  resultJson(%*{
    "projectDir": root,
    "profile": opts.profile,
    "features": selection.enabled,
    "nim": detectNimCompiler(),
    "atlas": (try: detectAtlas() except CatchableError: ""),
    "declared": {"nim": cfg.toolchain.nim, "atlas": cfg.toolchain.atlas}
  })

proc doctorOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Check configured toolchain requirements.
  let cfg = try: loadEffectiveConfig(projectDir) except CatchableError:
              initBauConfig()
  let check = checkToolchain(cfg)
  OperationResult(ok: check.ok, json: dependencyCheckNode(check))

proc shellInitResultNode(item: ShellInitResult): JsonNode =
  %*{
    "shell": item.shell,
    "configPath": item.configPath,
    "binDir": item.binDir,
    "changed": item.changed,
    "alreadyInPath": item.alreadyInPath,
    "alreadyConfigured": item.alreadyConfigured
  }

proc shellInitOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Add Bau's binary directory to the selected shell startup file.
  discard projectDir
  try:
    resultJson(shellInitResultNode(initShellPath(opts.shellName)))
  except CatchableError as e:
    errorJson(e.msg)

proc agentSetupOperation*(projectDir: string;
    opts: OperationOptions = defaultOperationOptions()): OperationResult =
  ## Write project-local MCP and skill setup for coding agents.
  try:
    let targets = normalizeAgentTargets(opts.agentTargets)
    let setup = setupAgents(projectDir, AgentSetupOptions(
      targets: targets,
      force: opts.force,
      dryRun: opts.dryRun))
    let node = agentSetupResultJson(setup)
    OperationResult(ok: node["ok"].getBool(), json: node)
  except CatchableError as e:
    errorJson(e.msg)
