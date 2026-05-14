## Runs named tasks with dependencies and cache integration.

import std/[os, options, sets, strutils, tables, times]
import bau/[argv, build, config, features, remote, taskcache, testexec, util]

type
  TaskRunOptions* = object      ## Options controlling task execution.
    profile*: string            ## Profile used by built-in task dependencies.
    verbose*: bool              ## Whether nested commands should print details.
    dryRun*: bool               ## Print planned work without running commands.
    force*: bool                ## Ignore freshness and cache hits.
    keepGoing*: bool            ## Continue independent tasks after failures.
    features*: FeatureSelection ## Feature selection exposed to tasks.
    taskArgs*: seq[string]      ## Arguments passed after `bau task <name> --`.

  TaskRunState = object
    root: string
    visiting: HashSet[string]
    completed: HashSet[string]
    failed: seq[string]

proc taskByName(cfg: BauConfig; name: string): Option[TaskInfo] =
  for task in cfg.tasks:
    if task.name == name:
      return some(task)
  result = none(TaskInfo)

proc hasPatternChars(path: string): bool =
  path.contains("*") or path.contains("?") or path.contains("[")

proc addPath(files: var seq[string]; projectDir, path: string) =
  let absPath = if path.isAbsolute: path else: projectDir / path
  if hasPatternChars(path):
    for f in walkPattern(absPath):
      if fileExists(f):
        files.add(f)
  elif fileExists(absPath):
    files.add(absPath)
  elif dirExists(absPath):
    for f in walkDirRec(absPath, yieldFilter = {pcFile}):
      files.add(f)

proc expandPaths(projectDir: string; paths: openArray[string]): seq[string] =
  for path in paths:
    result.addPath(projectDir, path)

proc newestTime(files: openArray[string]): Time =
  for f in files:
    if fileExists(f):
      let mtime = getLastModificationTime(f)
      if result == Time() or mtime > result:
        result = mtime

proc oldestTime(files: openArray[string]): Time =
  for f in files:
    if not fileExists(f):
      return Time()
    let mtime = getLastModificationTime(f)
    if result == Time() or mtime < result:
      result = mtime

proc taskIsFresh(task: TaskInfo; projectDir: string): bool =
  if task.inputs.len == 0 or task.outputs.len == 0:
    return false
  let inputs = expandPaths(projectDir, task.inputs)
  let outputs = expandPaths(projectDir, task.outputs)
  if inputs.len == 0 or outputs.len == 0:
    return false
  let inTime = newestTime(inputs)
  let outTime = oldestTime(outputs)
  result = outTime != Time() and inTime != Time() and outTime >= inTime

proc withTemporaryEnv(env: Table[string, string]; body: proc()) =
  var oldValues = initTable[string, Option[string]]()
  for key, val in env.pairs:
    if existsEnv(key):
      oldValues[key] = some(getEnv(key))
    else:
      oldValues[key] = none(string)
    putEnv(key, val)
  try:
    body()
  finally:
    for key, old in oldValues.pairs:
      if old.isSome:
        putEnv(key, old.get())
      else:
        delEnv(key)

proc joinedTaskArgs(args: openArray[string]): string =
  for i, arg in args:
    if i > 0:
      result.add(" ")
    result.add(quoteShell(arg))

proc withTaskArgs(cmd: string; args: openArray[string]): string =
  let joined = joinedTaskArgs(args)
  let joinedWithSep = if args.len > 0: "-- " & joined else: ""
  result = cmd.replace("{argsWithSep}", joinedWithSep)
  if args.len == 0:
    result = result.replace(" -- {args}", "")
    result = result.replace("-- {args}", "")
  result = result.replace("{args}", joined)

proc runShellCommand(task: TaskInfo; projectDir: string;
    featureSelection: FeatureSelection; profile: string;
    taskArgs: openArray[string]) =
  let cwd = task.cwd.get(projectDir)
  let argsForTask = @taskArgs
  proc invoke() =
    if task.cmd.endsWith(".nims"):
      let scriptPath = projectDir / task.cmd
      if not fileExists(scriptPath):
        raise newException(IOError, "nims file not found: " & task.cmd)
      runCmdLive(detectNimCompiler(), ["r", scriptPath], cwd)
    elif task.cmd.startsWith("http://") or task.cmd.startsWith("https://"):
      info("fetching remote task: " & task.cmd)
      let script = fetchRemoteTask(task.cmd)
      let tmpFile = getTempDir() / "bau-task-" & task.name & ".nims"
      saveFile(tmpFile, script)
      try:
        runCmdLive(detectNimCompiler(), ["r", tmpFile], cwd)
      finally:
        if fileExists(tmpFile):
          removeFile(tmpFile)
    elif task.shell.len > 0:
      runCmdLive(task.shell, ["-c", withTaskArgs(task.cmd, argsForTask)], cwd)
    else:
      let parts = parseCommandLine(withTaskArgs(task.cmd, argsForTask))
      if parts.len == 0:
        raise newException(ValueError, "task has an empty command: " & task.name)
      let args = if parts.len > 1: parts[1..^1] else: @[]
      runCmdLive(parts[0], args, cwd)
  var env = enabledFeatureEnv(featureSelection)
  env["BAU_PROFILE"] = profile
  env["BAU_TASK_ARGS"] = joinedTaskArgs(argsForTask)
  for i, arg in argsForTask:
    env["BAU_TASK_ARG_" & $i] = arg
  for key, val in task.env.pairs:
    env[key] = val
  withTemporaryEnv(env, invoke)

proc runBuiltinCommand(command: string; cfg: BauConfig; projectDir: string;
    opts: TaskRunOptions; profile: string): bool =
  case command
  of "build":
    if opts.dryRun:
      echo "build"
    else:
      buildAllTargets(cfg, profile, projectDir, opts.verbose, opts.features)
    result = true
  of "test":
    if opts.dryRun:
      echo "test --profile " & profile
    else:
      let testResult = runTests(cfg, projectDir, TestRunOptions(
        profile: profile,
        since: "HEAD",
        showOutput: tomAuto,
        verbose: opts.verbose,
        featureSelection: opts.features), useConfiguredProfiles = false)
      if testResult.failed > 0:
        raise newException(ValueError, "test command failed")
    result = true
  else:
    result = false

proc runBuiltinDependency(name: string; cfg: BauConfig; projectDir: string;
    opts: TaskRunOptions): bool =
  runBuiltinCommand(name, cfg, projectDir, opts, opts.profile)

proc taskCanUseCache(task: TaskInfo): bool =
  task.cache or (task.inputs.len > 0 and task.outputs.len > 0)

proc runTask(state: var TaskRunState; cfg: BauConfig; name, projectDir: string;
    opts: TaskRunOptions): bool =
  if state.completed.contains(name):
    return true
  if state.visiting.contains(name):
    raise newException(ValueError, "task dependency cycle involving '" & name & "'")

  let taskOpt = taskByName(cfg, name)
  if taskOpt.isNone:
    if runBuiltinDependency(name, cfg, projectDir, opts):
      state.completed.incl(name)
      return true
    raise newException(ValueError, "task '" & name & "' not found in bau.toml")

  state.visiting.incl(name)
  let task = taskOpt.get()
  var ok = true
  for dep in task.deps:
    try:
      if not runTask(state, cfg, dep, projectDir, opts):
        ok = false
    except CatchableError as e:
      ok = false
      state.failed.add(dep)
      error(e.msg)
      if not opts.keepGoing:
        raise

  if ok or opts.keepGoing:
    for required in task.requiredFeatures:
      if required notin opts.features.enabled:
        raise newException(ValueError, "task '" & name &
          "' requires feature '" & required & "'")
    let taskArgs = if name == state.root: opts.taskArgs else: @[]
    if taskArgs.len > 0 and not task.acceptArgs:
      raise newException(ValueError, "task '" & name &
        "' does not accept arguments; set acceptArgs = true")
    let taskProfile = if task.profile.len > 0: task.profile else: opts.profile
    let cacheEntry = taskCacheEntry(task, projectDir, cfg, taskProfile,
      opts.features, taskArgs)
    var remoteError = ""
    if not opts.force and cfg.cache.read and taskCanUseCache(task) and
        restoreTaskOutputs(cacheEntry, projectDir):
      success("task cache hit: " & name)
    elif not opts.force and cfg.cache.read and taskCanUseCache(task) and
        restoreRemoteTaskOutputs(cacheEntry, projectDir, cfg, remoteError):
      success("task remote cache hit: " & name)
    elif not opts.force and taskIsFresh(task, projectDir):
      success("task cached: " & name)
    elif opts.dryRun:
      let summary = if task.command.len > 0:
                      "bau " & task.command & " --profile " & taskProfile
                    else:
                      withTaskArgs(task.cmd, taskArgs)
      echo "task " & name & ": " & summary
    else:
      info("running task: " & name)
      try:
        if task.command.len > 0:
          if not runBuiltinCommand(task.command, cfg, projectDir, opts,
              taskProfile):
            raise newException(ValueError, "unknown task command: " &
              task.command)
        else:
          runShellCommand(task, projectDir, opts.features, taskProfile,
            taskArgs)
        if cfg.cache.write and taskCanUseCache(task):
          saveTaskOutputs(cacheEntry, task, projectDir)
          discard saveRemoteTaskOutputs(cacheEntry, task, projectDir, cfg)
      except CatchableError as e:
        ok = false
        state.failed.add(name)
        error(e.msg)
        if not opts.keepGoing:
          raise

  state.visiting.excl(name)
  if ok:
    state.completed.incl(name)
  result = ok

proc runTaskByName*(cfg: BauConfig; name, projectDir: string;
    opts: TaskRunOptions): bool =
  ## Run a named task and its dependencies.
  ##
  ## Returns false when one or more tasks failed under `keepGoing`.
  var state = TaskRunState(root: name)
  result = runTask(state, cfg, name, projectDir, opts)
  if state.failed.len > 0:
    error("failed task(s): " & state.failed.join(", "))
    result = false

proc taskNames*(cfg: BauConfig): seq[string] =
  ## Return task names declared in configuration order.
  for task in cfg.tasks:
    result.add(task.name)
