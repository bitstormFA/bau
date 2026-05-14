## Plans and runs Nim compiler invocations for Bau targets.

import std/[algorithm, os, osproc, strutils, tables, options]
import bau/[argv, util, config, fingerprint, features, buildscript]

type
  BuildContext* = object        ## Shared state for resolving and compiling targets.
    cfg*: BauConfig             ## Effective project configuration.
    profile*: string            ## Requested profile name.
    projectDir*: string         ## Project root directory.
    verbose*: bool              ## Whether command details should be printed.
    features*: FeatureSelection ## Resolved feature selection.

  TargetPlan* = object                    ## Fully resolved build plan for one target.
    target*: TargetInfo                   ## Target declaration being built.
    profile*: string                      ## Effective profile name.
    profileInfo*: ProfileInfo             ## Merged profile configuration.
    sourceDir*: string                    ## Source directory relative to the project root.
    mainFile*: string                     ## Main Nim file relative to the project root.
    outputName*: string                   ## Binary or library output name.
    outputDir*: string                    ## Directory where compiled output is written.
    binaryPath*: string                   ## Expected compiled artifact path.
    compilerFlags*: seq[string]           ## Nim compiler flags for this build.
    sourceFiles*: seq[string] ## Source and dependency files tracked by fingerprints.
    fingerprintInputs*: FingerprintInputs ## Inputs used to compute freshness.
    fingerprint*: Fingerprint             ## Computed freshness fingerprint.

proc initBuildContext*(cfg: BauConfig; profile, projectDir: string;
    verbose: bool;
    featureSelection: FeatureSelection = FeatureSelection()): BuildContext =
  ## Create a build context from config, profile, project path, and features.
  BuildContext(cfg: cfg, profile: profile, projectDir: projectDir,
    verbose: verbose, features: featureSelection)

proc resolveSourceFiles*(sourceDir: string; mainFile: string): seq[string] =
  ## Return the main file plus Nim source files beneath `sourceDir`.
  result = @[mainFile]
  let fullDir = if sourceDir.len > 0: sourceDir else: "."
  if dirExists(fullDir):
    for f in walkDirRec(fullDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim"):
        let absF = absolutePath(f)
        if absF notin result:
          result.add(absF)

proc collectCompilerFlags*(profile: ProfileInfo; kind: BuildKind;
    outDir: string; sourceDir: string; projectDir: string; cfg: BauConfig;
    featureSelection: FeatureSelection = FeatureSelection()): seq[string] =
  ## Build the Nim compiler flag list for a target.
  ##
  ## The result includes profile flags, feature defines, paths, output settings,
  ## color policy, and parallel-build defaults.
  result = @[]
  if kind == bkTest:
    result.add("-d:test")

  if profile.flags.len > 0:
    result.add(profile.flags)

  if profile.gc.len > 0:
    result.add("--mm:" & profile.gc)
  else:
    result.add("--mm:orc")

  for key, val in profile.define.pairs:
    if val.len > 0:
      result.add("-d:" & key & "=" & val)
    else:
      result.add("-d:" & key)
  result.add(compilerFeatureFlags(featureSelection))

  let color = getEnv("BAU_COLOR", "auto")
  if color == "always":
    result.add("--colors:on")
  elif color == "never":
    result.add("--colors:off")

  result.add("--outdir:" & outDir)
  result.add("--path:" & absolutePath(projectDir) / sourceDir)

  let depsDir = projectDir / "deps"
  if dirExists(depsDir):
    for kind, path in walkDir(depsDir):
      if kind == pcDir:
        result.add("--path:" & path)

  for name, dep in cfg.deps.pairs:
    if isSome(dep.path) and dependencyEnabled(cfg, name, dep, featureSelection):
      let depPath = absolutePath(projectDir) / get(dep.path)
      if dirExists(depPath / "src"):
        result.add("--path:" & depPath / "src")
      result.add("--path:" & depPath)

  result.add("--hints:off")
  var jobs = 0
  try:
    jobs = parseInt(getEnv("BAU_JOBS", "0"))
  except ValueError:
    jobs = 0
  if jobs <= 0:
    jobs = max(1, countProcessors())
  result.add("--parallelBuild:" & $jobs)

proc collectDepFiles*(projectDir: string): seq[string]
proc collectFingerprintConfigInputs*(projectDir: string): seq[string]
proc collectFingerprintEnvInputs*(): seq[string]

proc defaultTarget(cfg: BauConfig; profile: string): TargetInfo =
  TargetInfo(
    name: defaultTargetName(cfg),
    kind: cfg.build.kind,
    main: cfg.build.main,
    output: cfg.build.output,
    source: cfg.build.source,
    profile: profile)

proc resolveTargetPlan*(ctx: BuildContext; targetIdx: int): TargetPlan =
  ## Resolve a target index into compiler inputs, outputs, flags, and profile.
  ##
  ## `targetIdx == -1` selects the default `[build]` target.
  result.target = if targetIdx >= 0 and targetIdx < ctx.cfg.targets.len:
                    ctx.cfg.targets[targetIdx]
                  else:
                    defaultTarget(ctx.cfg, ctx.profile)
  result.profile = if result.target.profile.len > 0: result.target.profile
                   else: ctx.profile
  result.profileInfo = if result.profile.len > 0 and
      ctx.cfg.profiles.hasKey(result.profile):
    resolveProfile(ctx.cfg.profiles, result.profile)
  else:
    initProfileInfo()

  result.sourceDir = if result.target.source.len > 0: result.target.source
                     elif ctx.cfg.build.source.len > 0: ctx.cfg.build.source
                     else: "src"
  result.mainFile = if result.target.main.len > 0: result.target.main
                    else: (result.sourceDir / ctx.cfg.package.name & ".nim")
  result.outputName =
    if result.target.output.len > 0:
      result.target.output
    elif targetIdx >= 0 and result.target.name.len > 0:
      result.target.name
    elif ctx.cfg.build.output.len > 0:
      ctx.cfg.build.output
    else:
      ctx.cfg.package.name
  result.outputDir = absolutePath(ctx.projectDir) / BuildDirName / result.profile
  result.binaryPath = result.outputDir / result.outputName
  result.compilerFlags = collectCompilerFlags(result.profileInfo,
    result.target.kind, result.outputDir, result.sourceDir, ctx.projectDir,
    ctx.cfg, ctx.features)
  for path in result.target.paths:
    let fullPath = if path.isAbsolute: path else: absolutePath(ctx.projectDir) / path
    result.compilerFlags.add("--path:" & fullPath)

  result.sourceFiles = resolveSourceFiles(ctx.projectDir / result.sourceDir,
    ctx.projectDir / result.mainFile)
  result.sourceFiles.add(collectDepFiles(ctx.projectDir))

proc requireTargetFeatures(plan: TargetPlan; selection: FeatureSelection) =
  for required in plan.target.requiredFeatures:
    if required notin selection.enabled:
      raise newException(ValueError, "target '" & plan.outputName &
        "' requires feature '" & required & "'")

proc addBuildScriptInputs(plan: var TargetPlan; ctx: BuildContext;
    scriptResult: BuildScriptResult) =
  for path in scriptResult.rerunFiles:
    plan.sourceFiles.add(if path.isAbsolute: path else: ctx.projectDir / path)
  for path in scriptResult.generatedFiles:
    plan.sourceFiles.add(if path.isAbsolute: path else: ctx.projectDir / path)
  plan.compilerFlags.add(scriptResult.flags)

  var envInputs = collectFingerprintEnvInputs()
  for name in scriptResult.rerunEnv:
    envInputs.add("build-script:" & name & "=" & getEnv(name, ""))
  plan.fingerprintInputs = initFingerprintInputs(
    plan.sourceFiles,
    plan.compilerFlags,
    plan.profile,
    collectFingerprintConfigInputs(ctx.projectDir),
    envInputs)
  plan.fingerprint = computeFingerprint(plan.fingerprintInputs)

proc compileCommandForBackend(backend: string): string =
  case backend
  of "cpp": "cpp"
  of "js": "js"
  of "objc": "objc"
  else: "c"

proc runBuildHook(name, command, projectDir: string) =
  if command.len == 0:
    return
  let hookParts = parseCommandLine(command)
  if hookParts.len == 0:
    raise newException(ValueError, name & " hook is empty")
  let hookCmd = hookParts[0]
  let hookArgs = if hookParts.len > 1: hookParts[1..^1] else: @[]
  info(name & ": " & command)
  runCmdLive(hookCmd, hookArgs, cwd = projectDir)

proc compileTarget(ctx: BuildContext; plan: TargetPlan) =
  let nimCmd = detectNimCompiler()
  let backend = if plan.profileInfo.backend.len > 0: plan.profileInfo.backend
                else: ctx.cfg.build.backend
  var args = @[compileCommandForBackend(backend)]
  if plan.target.kind == bkTest:
    args.add("-r")
  args.add(plan.compilerFlags)
  args.add("--out:" & plan.binaryPath)
  args.add(plan.mainFile)

  if ctx.verbose:
    info("compiling " & plan.outputName & " (" & plan.profile & ")")
    echo nimCmd & " " & args.join(" ")

  runCmdLive(nimCmd, args, cwd = ctx.projectDir)

proc collectDepFiles*(projectDir: string): seq[string] =
  ## Return Nim files from materialized dependencies.
  result = @[]
  let depsDir = projectDir / "deps"
  if dirExists(depsDir):
    for kind, path in walkDir(depsDir):
      if kind == pcDir:
        if dirExists(path / "src"):
          for f in walkDirRec(path / "src", yieldFilter = {pcFile}):
            if f.endsWith(".nim"):
              result.add(f)
        else:
          for f in walkDirRec(path, yieldFilter = {pcFile}):
            if f.endsWith(".nim"):
              result.add(f)

proc collectFingerprintConfigInputs*(projectDir: string): seq[string] =
  ## Return config files included in build fingerprints.
  result.add(projectDir / ConfigFileName)
  let localPath = projectDir / LocalConfigFileName
  if fileExists(localPath):
    result.add(localPath)
  let globalPath = globalConfigPath()
  if fileExists(globalPath):
    result.add(globalPath)

proc collectFingerprintEnvInputs*(): seq[string] =
  ## Return environment entries included in build fingerprints.
  for key, val in envPairs():
    if key.startsWith("BAU_") or key in ["PATH", "NIM", "ATLAS"]:
      result.add(key & "=" & val)
  result.sort()

proc buildTarget*(cfg: BauConfig; targetIdx: int; profile: string;
    projectDir: string; verbose: bool;
    featureSelection: FeatureSelection = FeatureSelection()): string =
  ## Build one target and return the produced artifact path.
  ##
  ## Cached fingerprints are used to skip unchanged builds.
  let ctx = initBuildContext(cfg, profile, projectDir, verbose, featureSelection)
  var plan = resolveTargetPlan(ctx, targetIdx)
  plan.requireTargetFeatures(featureSelection)

  let fpDir = absolutePath(projectDir) / BuildDirName / FingerprintDirName

  let savedFp = loadFingerprint(fpDir, plan.outputName, "main")

  let scriptResult = runBuildScripts(cfg, projectDir, plan.profile,
    featureSelection, verbose)
  plan.addBuildScriptInputs(ctx, scriptResult)

  if isSome(savedFp) and get(savedFp) == plan.fingerprint and
      fileExists(plan.binaryPath):
    success("cached   " & plan.outputName & " (" & plan.profile & ")")
    result = plan.binaryPath
    return

  runBuildHook("preBuild", cfg.scripts.preBuild.get(""), projectDir)
  compileTarget(ctx, plan)
  runBuildHook("postBuild", cfg.scripts.postBuild.get(""), projectDir)

  saveFingerprint(fpDir, plan.outputName, "main", plan.fingerprint)

  if not fileExists(plan.binaryPath):
    raise newException(IOError, "build did not produce expected binary: " &
      plan.binaryPath)

  success("built    " & plan.outputName & " (" & plan.profile & ")")
  result = plan.binaryPath

proc findTargetIndex*(cfg: BauConfig; name: string): int =
  ## Return the index of a named explicit target, or `-1` when absent.
  for i, t in cfg.targets:
    if t.name == name:
      return i
  return -1

proc buildSingleTarget*(cfg: BauConfig; profile: string; projectDir: string;
    verbose: bool; featureSelection: FeatureSelection = FeatureSelection()): string =
  ## Build the default target and return its artifact path.
  buildTarget(cfg, -1, profile, projectDir, verbose, featureSelection)

proc buildAllTargets*(cfg: BauConfig; profile: string; projectDir: string;
    verbose: bool; featureSelection: FeatureSelection = FeatureSelection()) =
  ## Build configured targets, including the default target when requested.
  if cfg.targets.len == 0 or cfg.build.includeDefault:
    discard buildTarget(cfg, -1, profile, projectDir, verbose, featureSelection)
    if cfg.targets.len == 0:
      return
  let defaultName = defaultTargetName(cfg)
  let defaultOutput = if cfg.build.output.len >
      0: cfg.build.output else: defaultName
  for i in 0..<cfg.targets.len:
    let name = cfg.targets[i].name
    let outputName = if cfg.targets[i].output.len > 0:
                       cfg.targets[i].output
                     else:
                       name
    if not cfg.build.includeDefault or
        (name != defaultName and outputName != defaultName and
        outputName != defaultOutput):
      info("building target: " & name)
      discard buildTarget(cfg, i, profile, projectDir, verbose,
        featureSelection)

proc buildTargetByName*(cfg: BauConfig; name: string; profile: string;
    projectDir: string; verbose: bool;
    featureSelection: FeatureSelection = FeatureSelection()): string =
  ## Build a named explicit target and return its artifact path.
  let idx = findTargetIndex(cfg, name)
  if idx >= 0:
    result = buildTarget(cfg, idx, profile, projectDir, verbose, featureSelection)
  elif name == defaultTargetName(cfg):
    result = buildTarget(cfg, -1, profile, projectDir, verbose,
      featureSelection)
  else:
    raise newException(ValueError, "target not found: " & name)

proc runTarget*(cfg: BauConfig; targetIdx: int; profile: string;
    projectDir: string; runArgs: openArray[string]; verbose: bool;
    featureSelection: FeatureSelection = FeatureSelection()) =
  ## Build a target by index, then run the produced artifact.
  let binPath = buildTarget(cfg, targetIdx, profile, projectDir, verbose,
    featureSelection)
  runCmdLive(binPath, runArgs, cwd = projectDir)

proc runTargetByName*(cfg: BauConfig; name: string; profile: string;
    projectDir: string; runArgs: openArray[string]; verbose: bool;
    featureSelection: FeatureSelection = FeatureSelection()) =
  ## Build a target by name, then run the produced artifact.
  let idx = findTargetIndex(cfg, name)
  let targetIdx = if idx >= 0: idx else: -1
  if idx < 0 and name != defaultTargetName(cfg):
    raise newException(ValueError, "target not found: " & name)
  let binPath = buildTarget(cfg, targetIdx, profile, projectDir, verbose,
    featureSelection)
  runCmdLive(binPath, runArgs, cwd = projectDir)

proc cleanBuild*() =
  ## Remove the default build directory in the current project.
  let buildDir = getCurrentDir() / BuildDirName
  if dirExists(buildDir):
    info("removing " & buildDir)
    removeDir(buildDir)
  success("clean")
