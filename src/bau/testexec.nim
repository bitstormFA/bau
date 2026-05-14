## Discovers and runs project tests according to Bau configuration.

import std/[algorithm, os, sets, strutils, tables]
import bau/[affected, build, config, features, util]

type
  TestOutputMode* = enum ## How test process output is shown.
    tomAuto = "auto"     ## Stream configured runners, capture small test files.
    tomAlways = "always" ## Stream all test process output live.
    tomNever = "never"   ## Capture output and print only Bau summaries.

  TestRunOptions* = object              ## Options controlling a `bau test` run.
    profile*: string                    ## Requested profile when no test matrix is configured.
    filter*: string                     ## Optional filename/path substring filter.
    changed*: bool                      ## Whether to limit to affected test files.
    since*: string                      ## Git ref used for changed-test detection.
    passthroughArgs*: seq[string]       ## Arguments passed to test programs.
    showOutput*: TestOutputMode         ## Output capture/streaming policy.
    verbose*: bool                      ## Whether captured successful output is printed.
    featureSelection*: FeatureSelection ## Enabled feature set.

  TestCase* = object ## One runner or test file selected for execution.
    path*: string    ## Absolute path to the Nim test file.
    runner*: bool    ## True when this file is acting as an aggregate runner.

  TestRunResult* = object ## Aggregate test result counters.
    passed*: int          ## Number of passed profile/file invocations.
    failed*: int          ## Number of failed profile/file invocations.

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

proc effectiveTestProfiles*(cfg: BauConfig; requestedProfile: string;
    useConfiguredProfiles = true): seq[string] =
  ## Return the profile matrix used by a test run.
  if useConfiguredProfiles and cfg.test.profiles.len > 0:
    result = cfg.test.profiles
  elif cfg.profiles.hasKey("test") and requestedProfile.len == 0:
    result = @["test"]
  elif cfg.profiles.hasKey("test") and requestedProfile == "dev":
    result = @["test"]
  else:
    result = @[requestedProfile]

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
  if fileExists(runner) and not opts.changed and opts.filter.len == 0:
    return @[TestCase(path: runner, runner: true)]

  var changedTests = initHashSet[string]()
  if opts.changed:
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

proc runOneTest(cfg: BauConfig; projectDir, profile: string; test: TestCase;
    opts: TestRunOptions): bool =
  let prof = profileInfo(cfg, profile)
  let outDir = absolutePath(projectDir) / BuildDirName / profile
  let flags = collectCompilerFlags(prof, bkTest, outDir, cfg.build.source,
    projectDir, cfg, opts.featureSelection)
  var args = @["c", "-r"]
  args.add(flags)
  args.add(test.path)
  args.add(opts.passthroughArgs)

  let rel = relProjectPath(projectDir, test.path)
  let label = rel & " (" & profile & ")"
  let stream = opts.showOutput == tomAlways or
    (opts.showOutput == tomAuto and test.runner)

  var exitCode = 0
  if stream:
    info("running " & label)
    exitCode = runCmdLiveStatus(detectNimCompiler(), args, projectDir)
  else:
    let run = runCmd(detectNimCompiler(), args, projectDir)
    exitCode = run.exitCode
    if run.output.len > 0 and (opts.verbose or
        (exitCode != 0 and opts.showOutput != tomNever)):
      echo run.output

  if exitCode == 0:
    success(label & " passed")
    result = true
  else:
    error(label & " failed")
    result = false

proc runTests*(cfg: BauConfig; projectDir: string; opts: TestRunOptions;
    useConfiguredProfiles = true): TestRunResult =
  ## Run selected tests and return aggregate counters.
  let cases = collectTestCases(cfg, projectDir, opts)
  if cases.len == 0:
    raise newException(ValueError, "no test files found" &
      (if opts.filter.len > 0: " matching '" & opts.filter & "'" else: ""))

  let profiles = effectiveTestProfiles(cfg, opts.profile, useConfiguredProfiles)
  info("running " & $cases.len & " test file(s) across " & $profiles.len &
    " profile(s)...")
  if cases.len == 1 and cases[0].runner:
    info("using test runner: " & relProjectPath(projectDir, cases[0].path))

  for profile in profiles:
    for test in cases:
      if runOneTest(cfg, projectDir, profile, test, opts):
        result.passed += 1
      else:
        result.failed += 1
