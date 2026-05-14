## Discovers, plans, and runs project tests according to Bau configuration.

import std/[algorithm, monotimes, options, os, osproc, sets, strutils, tables,
  times]
import bau/[affected, build, config, features, fingerprint, util]

type
  TestOutputMode* = enum ## How test process output is shown.
    tomAuto = "auto"     ## Stream configured runners, capture small test files.
    tomAlways = "always" ## Stream all test process output live.
    tomNever = "never"   ## Capture output and print only Bau summaries.

  TestRunOptions* = object              ## Options controlling a `bau test` run.
    profile*: string                    ## Requested profile when no test matrix is configured.
    profileExplicit*: bool              ## Whether the profile came from CLI input.
    filter*: string                     ## Optional filename/path substring filter.
    changed*: bool                      ## Whether to limit to affected test files.
    since*: string                      ## Git ref used for changed-test detection.
    passthroughArgs*: seq[string]       ## Arguments passed to test programs.
    showOutput*: TestOutputMode         ## Output capture/streaming policy.
    verbose*: bool                      ## Whether captured successful output is printed.
    dryRun*: bool                       ## Print planned invocations without executing them.
    jobs*: int                          ## Maximum test file invocations to run at once.
    jobsExplicit*: bool                 ## Whether jobs came from CLI input.
    timings*: bool                      ## Whether per-test timings should be printed.
    noMatrix*: bool                     ## Force one profile instead of the configured matrix.
    full*: bool                         ## Force the full configured test matrix.
    fast*: bool                         ## Use the fast local test mode.
    noRunner*: bool                     ## Discover test files instead of using a runner.
    featureSelection*: FeatureSelection ## Enabled feature set.

  TestCase* = object ## One runner or test file selected for execution.
    path*: string    ## Absolute path to the Nim test file.
    runner*: bool    ## True when this file is acting as an aggregate runner.

  TestInvocationTiming* = object ## Timing data for one profile/file invocation.
    profile*: string             ## Display profile name.
    path*: string                ## Project-relative test path.
    cached*: bool                ## True when compilation was skipped.
    compileMs*: int64            ## Milliseconds spent compiling.
    runMs*: int64                ## Milliseconds spent running.
    totalMs*: int64              ## Compile plus run milliseconds.
    passed*: bool                ## True when compile and run both succeeded.

  TestRunResult* = object ## Aggregate test result counters.
    planned*: int         ## Number of planned profile/file invocations.
    passed*: int          ## Number of passed profile/file invocations.
    failed*: int          ## Number of failed profile/file invocations.
    timings*: seq[TestInvocationTiming] ## Per-invocation timing details.

  TestInvocation = object
    profile: string
    displayProfile: string
    test: TestCase
    rel: string
    label: string
    compilerArgs: seq[string]
    runArgs: seq[string]
    binaryPath: string
    fingerprintTarget: string
    fingerprintUnit: string
    fingerprintValue: Fingerprint
    compileNeeded: bool
    cacheReason: string
    streamOutput: bool

  TestPhase = enum
    tpCompile
    tpRun

  ActiveTest = object
    index: int
    phase: TestPhase
    process: Process
    started: MonoTime
    outputPath: string
    streamOutput: bool

  InvocationState = object
    compileMs: int64
    runMs: int64
    cached: bool
    failed: bool

proc parseTestOutputMode*(value: string): TestOutputMode =
  ## Parse a user-facing test output mode string.
  case value
  of "", "auto":
    tomAuto
  of "always":
    tomAlways
  of "never":
    tomNever
  else:
    raise newException(ValueError, "unknown test output mode: " & value)

proc effectiveTestOutputMode*(cfg: BauConfig;
    override: string): TestOutputMode =
  ## Return the effective test output mode from CLI or `[test]`.
  if override.len > 0:
    parseTestOutputMode(override)
  else:
    parseTestOutputMode(cfg.test.showOutput)

proc singleTestProfile(cfg: BauConfig; requestedProfile: string): string =
  if cfg.test.defaultProfile.len > 0:
    return cfg.test.defaultProfile
  if cfg.profiles.hasKey("test") and requestedProfile.len == 0:
    return "test"
  if cfg.profiles.hasKey("test") and requestedProfile == "dev":
    return "test"
  result = requestedProfile

proc effectiveTestProfiles*(cfg: BauConfig; requestedProfile: string;
    useConfiguredProfiles = true; profileExplicit = false; noMatrix = false;
    full = false; fast = false): seq[string] =
  ## Return the profile matrix used by a test run.
  if full:
    if cfg.test.fullProfiles.len > 0:
      return cfg.test.fullProfiles
    if cfg.test.profiles.len > 0:
      return cfg.test.profiles
    if profileExplicit:
      return @[requestedProfile]
    return @[singleTestProfile(cfg, requestedProfile)]
  if profileExplicit:
    return @[requestedProfile]
  if noMatrix or fast:
    return @[singleTestProfile(cfg, requestedProfile)]
  if cfg.test.defaultProfile.len > 0:
    return @[cfg.test.defaultProfile]
  if useConfiguredProfiles and cfg.test.profiles.len > 0:
    return cfg.test.profiles
  result = @[singleTestProfile(cfg, requestedProfile)]

proc projectPath(projectDir, path: string): string =
  if path.isAbsolute:
    path
  else:
    projectDir / path

proc relProjectPath(projectDir, path: string): string =
  relativePath(path, projectDir).replace("\\", "/")

proc testRunner(cfg: BauConfig; projectDir: string): string =
  if cfg.test.runner.len > 0:
    projectPath(projectDir, cfg.test.runner)
  else:
    projectDir / "tests" / "tester.nim"

proc pathExcluded(cfg: BauConfig; projectDir, path: string): bool =
  let name = path.extractFilename
  let rel = relProjectPath(projectDir, path)
  if name == "tester.nim" or name == "thelper.nim":
    return true
  for item in cfg.test.exclude:
    let clean = item.replace("\\", "/")
    if clean == name or clean == rel or rel.endsWith("/" & clean):
      return true
  result = false

proc discoverTestFiles(cfg: BauConfig; projectDir, filter: string;
    changedTests: HashSet[string]): seq[string] =
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    if cfg.test.recursive:
      for file in walkDirRec(testDir, yieldFilter = {pcFile}):
        let name = file.extractFilename
        let rel = relProjectPath(projectDir, file)
        let selected = name.startsWith("t") and name.endsWith(".nim") and
          not pathExcluded(cfg, projectDir, file) and
          (filter.len == 0 or filter in name or filter in rel) and
          (changedTests.len == 0 or changedTests.contains(absolutePath(file)))
        if selected:
          result.add(file)
    else:
      for file in walkFiles(testDir / "t*.nim"):
        let name = file.extractFilename
        let rel = relProjectPath(projectDir, file)
        let selected = not pathExcluded(cfg, projectDir, file) and
          (filter.len == 0 or filter in name or filter in rel) and
          (changedTests.len == 0 or changedTests.contains(absolutePath(file)))
        if selected:
          result.add(file)
  result.sort()

proc collectTestCases*(cfg: BauConfig; projectDir: string;
    opts: TestRunOptions): seq[TestCase] =
  ## Return runner or individual test files selected for a test run.
  let runner = testRunner(cfg, projectDir)
  let changedMode = opts.changed or opts.fast
  let directParallel = opts.jobsExplicit and opts.jobs > 1
  if fileExists(runner) and not changedMode and opts.filter.len == 0 and
      not opts.noRunner and not directParallel:
    return @[TestCase(path: runner, runner: true)]

  var changedTests = initHashSet[string]()
  if changedMode:
    let report = computeAffected(cfg, projectDir, opts.since)
    for testFile in report.tests:
      changedTests.incl(absolutePath(projectDir / testFile))

  for file in discoverTestFiles(cfg, projectDir, opts.filter, changedTests):
    result.add(TestCase(path: file))

proc profileInfo(cfg: BauConfig; profile: string): ProfileInfo =
  if profile.len > 0 and cfg.profiles.hasKey(profile):
    resolveProfile(cfg.profiles, profile)
  else:
    initProfileInfo()

proc displayProfile(profile: string): string =
  if profile.len > 0:
    profile
  else:
    "default"

proc profileDir(profile: string): string =
  if profile.len > 0:
    profile
  else:
    "default"

proc safeUnitName(rel: string): string =
  let noExt = rel.changeFileExt("")
  for ch in noExt:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "test"

proc binaryExt(): string =
  when defined(windows):
    ".exe"
  else:
    ""

proc addUnique(files: var seq[string]; seen: var HashSet[string]; path: string) =
  let clean = absolutePath(path)
  if not seen.contains(clean):
    seen.incl(clean)
    files.add(clean)

proc testSourceFiles(cfg: BauConfig; projectDir: string;
    test: TestCase): seq[string] =
  var seen = initHashSet[string]()
  result.addUnique(seen, test.path)

  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let absSource = projectDir / sourceDir
  if dirExists(absSource):
    for file in walkDirRec(absSource, yieldFilter = {pcFile}):
      if file.endsWith(".nim"):
        result.addUnique(seen, file)

  let testDir = projectDir / "tests"
  if dirExists(testDir):
    for file in walkDirRec(testDir, yieldFilter = {pcFile}):
      if not file.endsWith(".nim"):
        continue
      let name = file.extractFilename
      if test.runner or not name.startsWith("t"):
        result.addUnique(seen, file)

  for file in collectDepFiles(projectDir):
    result.addUnique(seen, file)

proc tuneParallelBuild(flags: seq[string]; jobs: int): seq[string] =
  result = flags
  if jobs <= 1:
    return
  for i in 0..<result.len:
    if result[i].startsWith("--parallelBuild:"):
      result[i] = "--parallelBuild:1"
      return
  result.add("--parallelBuild:1")

proc fingerprintDiffSummary(cached, fresh: Fingerprint): string =
  var parts: seq[string]
  if cached.sourceHash != fresh.sourceHash:
    parts.add("source changed")
  if cached.flagsHash != fresh.flagsHash:
    parts.add("compiler flags changed")
  if cached.configHash != fresh.configHash:
    parts.add("config changed")
  if cached.envHash != fresh.envHash:
    parts.add("environment changed")
  if cached.compilerHash != fresh.compilerHash or
      cached.toolchain != fresh.toolchain:
    parts.add("toolchain changed")
  if cached.platform != fresh.platform:
    parts.add("platform changed")
  if cached.profile != fresh.profile:
    parts.add("profile changed")
  if cached.mtimeHash != fresh.mtimeHash:
    parts.add("source timestamps changed")
  if parts.len == 0:
    result = "fingerprint changed"
  elif parts.len <= 3:
    result = parts.join(", ")
  else:
    result = parts[0..2].join(", ") & ", ..."

proc streamFor(opts: TestRunOptions; test: TestCase): bool =
  opts.showOutput == tomAlways or (opts.showOutput == tomAuto and test.runner)

proc prepareInvocation(cfg: BauConfig; projectDir, profile: string;
    test: TestCase; opts: TestRunOptions): TestInvocation =
  result.profile = profile
  result.displayProfile = displayProfile(profile)
  result.test = test
  result.rel = relProjectPath(projectDir, test.path)
  result.label = result.rel & " (" & result.displayProfile & ")"

  let prof = profileInfo(cfg, profile)
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let outDir = absolutePath(projectDir) / BuildDirName / profileDir(profile)
  var flags = collectCompilerFlags(prof, bkTest, outDir, sourceDir,
    projectDir, cfg, opts.featureSelection).tuneParallelBuild(opts.jobs)

  result.fingerprintUnit = safeUnitName(result.rel)
  result.fingerprintTarget = "tests" / profileDir(profile)
  result.binaryPath = outDir / "tests" / result.fingerprintUnit & binaryExt()
  let nimcacheDir = outDir / ".nimcache" / result.fingerprintUnit

  result.compilerArgs = @["c"]
  result.compilerArgs.add(flags)
  result.compilerArgs.add("--nimcache:" & nimcacheDir)
  result.compilerArgs.add("--out:" & result.binaryPath)
  result.compilerArgs.add(test.path)
  result.runArgs = opts.passthroughArgs
  result.streamOutput = streamFor(opts, test)

  let inputs = initFingerprintInputs(
    testSourceFiles(cfg, projectDir, test),
    result.compilerArgs,
    profile,
    collectFingerprintConfigInputs(projectDir),
    collectFingerprintEnvInputs())
  result.fingerprintValue = computeFingerprint(inputs)

  let fpDir = absolutePath(projectDir) / BuildDirName / FingerprintDirName
  let saved = loadFingerprint(fpDir, result.fingerprintTarget,
    result.fingerprintUnit)
  if not fileExists(result.binaryPath):
    result.compileNeeded = true
    result.cacheReason = "output missing"
  elif saved.isNone:
    result.compileNeeded = true
    result.cacheReason = "no cached fingerprint"
  elif saved.get() == result.fingerprintValue:
    result.compileNeeded = false
    result.cacheReason = "fresh"
  else:
    result.compileNeeded = true
    result.cacheReason = fingerprintDiffSummary(saved.get(),
      result.fingerprintValue)

proc collectInvocations(cfg: BauConfig; projectDir: string;
    opts: TestRunOptions; useConfiguredProfiles: bool): seq[TestInvocation] =
  let cases = collectTestCases(cfg, projectDir, opts)
  if cases.len == 0:
    raise newException(ValueError, "no test files found" &
      (if opts.filter.len > 0: " matching '" & opts.filter & "'" else: ""))

  let profiles = effectiveTestProfiles(cfg, opts.profile, useConfiguredProfiles,
    opts.profileExplicit, opts.noMatrix, opts.full, opts.fast)
  info("planning " & $cases.len & " test file(s) across " & $profiles.len &
    " profile(s)...")
  if cases.len == 1 and cases[0].runner:
    info("using test runner: " & relProjectPath(projectDir, cases[0].path))

  for profile in profiles:
    for test in cases:
      result.add(prepareInvocation(cfg, projectDir, profile, test, opts))

proc printTestPlan(invocations: openArray[TestInvocation]) =
  info("planned " & $invocations.len & " test invocation(s)")
  for invocation in invocations:
    echo "test " & invocation.rel & " (" & invocation.displayProfile & ")"

proc quoteCommand(cmd: string; args: openArray[string]): string =
  result = quoteShell(cmd)
  for arg in args:
    result.add(" " & quoteShell(arg))

proc shellProcess(commandLine: string; cwd: string): Process =
  when defined(windows):
    let shell = getEnv("COMSPEC", "cmd.exe")
    startProcess(shell, args = @["/C", commandLine],
      options = {poParentStreams, poUsePath}, workingDir = cwd)
  else:
    startProcess("/bin/sh", args = @["-c", commandLine],
      options = {poParentStreams, poUsePath}, workingDir = cwd)

proc startCommand(cmd: string; args: openArray[string]; cwd: string;
    streamOutput: bool; outputPath: string): Process =
  if streamOutput:
    startProcess(cmd, args = @args, options = {poParentStreams, poUsePath},
      workingDir = cwd)
  else:
    createDir(parentDir(outputPath))
    let line = quoteCommand(cmd, args) & " > " & quoteShell(outputPath) &
      " 2>&1"
    shellProcess(line, cwd)

proc tempOutputPath(index: int; phase: TestPhase): string =
  getTempDir() / ("bau-test-" & $getCurrentProcessId() & "-" & $index &
    "-" & $phase & ".log")

proc readAndRemove(path: string): string =
  if path.len > 0 and fileExists(path):
    result = readFile(path)
    try:
      removeFile(path)
    except OSError:
      discard

proc maybePrintOutput(output: string; exitCode: int; opts: TestRunOptions) =
  if output.len > 0 and (opts.verbose or
      (exitCode != 0 and opts.showOutput != tomNever)):
    stdout.write(output)
    if not output.endsWith("\n"):
      echo ""

proc startPhase(invocations: seq[TestInvocation];
    states: var seq[InvocationState]; active: var seq[ActiveTest];
    index: int; phase: TestPhase; projectDir: string) =
  let invocation = invocations[index]
  var cmd: string
  var args: seq[string]
  case phase
  of tpCompile:
    info("compiling " & invocation.label & ": " & invocation.cacheReason)
    createDir(parentDir(invocation.binaryPath))
    cmd = detectNimCompiler()
    args = invocation.compilerArgs
  of tpRun:
    if invocation.streamOutput:
      info("running " & invocation.label)
    cmd = invocation.binaryPath
    args = invocation.runArgs

  let outputPath = if invocation.streamOutput: "" else: tempOutputPath(index, phase)
  let started = getMonoTime()
  let process = startCommand(cmd, args, projectDir, invocation.streamOutput,
    outputPath)
  active.add(ActiveTest(index: index, phase: phase, process: process,
    started: started, outputPath: outputPath,
    streamOutput: invocation.streamOutput))

proc finishActive(activeTest: ActiveTest; invocations: seq[TestInvocation];
    states: var seq[InvocationState]; active: var seq[ActiveTest];
    projectDir: string; opts: TestRunOptions; result: var TestRunResult) =
  let exitCode = activeTest.process.waitForExit()
  close(activeTest.process)
  let elapsed = (getMonoTime() - activeTest.started).inMilliseconds
  let output = if activeTest.streamOutput: "" else:
                 readAndRemove(activeTest.outputPath)
  let invocation = invocations[activeTest.index]

  case activeTest.phase
  of tpCompile:
    states[activeTest.index].compileMs = elapsed
    maybePrintOutput(output, exitCode, opts)
    if exitCode != 0:
      states[activeTest.index].failed = true
      result.failed += 1
      error(invocation.label & " compile failed")
      return
    if not fileExists(invocation.binaryPath):
      states[activeTest.index].failed = true
      result.failed += 1
      error(invocation.label & " compile did not produce " &
        invocation.binaryPath)
      return
    let fpDir = absolutePath(projectDir) / BuildDirName / FingerprintDirName
    saveFingerprint(fpDir, invocation.fingerprintTarget,
      invocation.fingerprintUnit, invocation.fingerprintValue)
    startPhase(invocations, states, active, activeTest.index, tpRun, projectDir)
  of tpRun:
    states[activeTest.index].runMs = elapsed
    maybePrintOutput(output, exitCode, opts)
    if exitCode == 0:
      result.passed += 1
      success(invocation.label & " passed")
    else:
      states[activeTest.index].failed = true
      result.failed += 1
      error(invocation.label & " failed")

proc hasRunner(invocations: openArray[TestInvocation]): bool =
  for invocation in invocations:
    if invocation.test.runner:
      return true

proc appendTimings(result: var TestRunResult;
    invocations: openArray[TestInvocation];
    states: openArray[InvocationState]) =
  for i, invocation in invocations:
    let compileMs = states[i].compileMs
    let runMs = states[i].runMs
    result.timings.add(TestInvocationTiming(
      profile: invocation.displayProfile,
      path: invocation.rel,
      cached: states[i].cached,
      compileMs: compileMs,
      runMs: runMs,
      totalMs: compileMs + runMs,
      passed: not states[i].failed))

proc printTimings(timings: openArray[TestInvocationTiming]) =
  if timings.len == 0:
    return
  echo ""
  info("test timings:")
  for item in timings:
    let cacheNote = if item.cached: "cached, " else: ""
    echo "  " & item.path & " (" & item.profile & "): " & cacheNote &
      "compile " & $item.compileMs & " ms, run " & $item.runMs &
      " ms, total " & $item.totalMs & " ms"

  var profileTotals = initTable[string, tuple[
    count: int,
    compileMs: int64,
    runMs: int64,
    totalMs: int64
  ]]()
  for item in timings:
    var entry = profileTotals.getOrDefault(item.profile)
    inc entry.count
    entry.compileMs += item.compileMs
    entry.runMs += item.runMs
    entry.totalMs += item.totalMs
    profileTotals[item.profile] = entry

  var profiles: seq[string]
  for profile in profileTotals.keys:
    profiles.add(profile)
  profiles.sort()
  if profiles.len > 0:
    info("profile timing totals:")
    for profile in profiles:
      let entry = profileTotals[profile]
      echo "  " & profile & ": " & $entry.count & " invocation(s), compile " &
        $entry.compileMs & " ms, run " & $entry.runMs & " ms, total " &
        $entry.totalMs & " ms"

  var slowest = @timings
  slowest.sort(proc(a, b: TestInvocationTiming): int =
    cmp(b.totalMs, a.totalMs))
  let limit = min(5, slowest.len)
  if limit > 0:
    info("slowest test invocation(s):")
    for i in 0..<limit:
      let item = slowest[i]
      echo "  " & item.path & " (" & item.profile & "): " &
        $item.totalMs & " ms"

proc executeInvocations(invocations: seq[TestInvocation]; projectDir: string;
    opts: TestRunOptions): TestRunResult =
  result.planned = invocations.len
  var states = newSeq[InvocationState](invocations.len)
  var active: seq[ActiveTest]
  var next = 0
  let maxJobs = if hasRunner(invocations): 1 else: max(1, opts.jobs)

  while next < invocations.len or active.len > 0:
    while next < invocations.len and active.len < maxJobs:
      if invocations[next].compileNeeded:
        startPhase(invocations, states, active, next, tpCompile, projectDir)
      else:
        states[next].cached = true
        success("cached   " & invocations[next].label)
        startPhase(invocations, states, active, next, tpRun, projectDir)
      inc next

    var i = 0
    while i < active.len:
      if not running(active[i].process):
        let done = active[i]
        active.delete(i)
        finishActive(done, invocations, states, active, projectDir, opts,
          result)
      else:
        inc i

    if active.len > 0:
      sleep(20)

  result.appendTimings(invocations, states)

proc runTests*(cfg: BauConfig; projectDir: string; opts: TestRunOptions;
    useConfiguredProfiles = true): TestRunResult =
  ## Run selected tests and return aggregate counters.
  let invocations = collectInvocations(cfg, projectDir, opts,
    useConfiguredProfiles)
  result.planned = invocations.len
  if opts.dryRun:
    printTestPlan(invocations)
    return

  result = executeInvocations(invocations, projectDir, opts)
  if opts.timings:
    printTimings(result.timings)
