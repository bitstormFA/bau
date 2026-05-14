## Stores and restores cached outputs for declared Bau tasks.

import std/[algorithm, base64, httpclient, json, options, os, strutils, tables,
  times]
import bau/[config, features, util]

type
  TaskCacheEntry* = object ## Address of cached outputs for one task key.
    key*: string           ## Deterministic cache key for the task invocation.
    taskName*: string      ## Task name associated with the cache entry.
    path*: string          ## Local filesystem path for the cache entry.
    outputs*: seq[string]  ## Output patterns allowed to be restored.

  TaskCacheExplain* = object ## Diagnostic data for a task cache lookup.
    task*: string            ## Task name being explained.
    key*: string             ## Computed cache key.
    path*: string            ## Local cache entry path.
    localHit*: bool          ## True when a matching local entry exists.
    remoteHit*: bool         ## True when a matching remote entry exists.
    remoteError*: string     ## Remote lookup error, if any.
    keyInputs*: seq[string]  ## Inputs that contributed to the cache key.
    outputs*: seq[string]    ## Output patterns declared by the task.

const RemotePayloadVersion = 1
const CacheLockTimeoutMs = 5000

proc hasPatternChars(path: string): bool =
  path.contains("*") or path.contains("?") or path.contains("[")

proc addPath(files: var seq[string]; projectDir, path: string) =
  let absPath = if path.isAbsolute: path else: projectDir / path
  if hasPatternChars(path):
    for f in walkPattern(absPath):
      if fileExists(f):
        files.add(f)
      elif dirExists(f):
        for child in walkDirRec(f, yieldFilter = {pcFile}):
          files.add(child)
  elif fileExists(absPath):
    files.add(absPath)
  elif dirExists(absPath):
    for f in walkDirRec(absPath, yieldFilter = {pcFile}):
      files.add(f)

proc expandPaths(projectDir: string; paths: openArray[string]): seq[string] =
  for path in paths:
    result.addPath(projectDir, path)
  result.sort()

proc cacheRoot*(projectDir: string; cfg: BauConfig): string =
  ## Resolve the task-cache root directory for a project.
  if cfg.cache.dir.isAbsolute:
    cfg.cache.dir
  else:
    projectDir / cfg.cache.dir

proc sortedEnvKeys(env: Table[string, string]): seq[string] =
  for key in env.keys:
    result.add(key)
  result.sort()

proc taskCacheKeyInputs*(task: TaskInfo; projectDir, profile: string;
    cfg: BauConfig; selection: FeatureSelection = FeatureSelection();
    taskArgs: openArray[string] = []): seq[string] =
  ## Return the textual inputs used to derive a task cache key.
  result.add("task:" & task.name)
  result.add("cmd:" & task.cmd)
  result.add("command:" & task.command)
  result.add("profile:" & profile)
  result.add("platform:" & platformTriple())
  result.add("nim:" & nimVersion())
  result.add("cwd:" & task.cwd.get(projectDir))
  result.add("shell:" & task.shell)
  for feature in selection.enabled:
    result.add("feature:" & feature)
  for dep in selection.enabledDeps:
    result.add("feature-dep:" & dep)
  for key in sortedEnvKeys(task.env):
    result.add("env:" & key & "=" & task.env[key])
  for key in task.envInputs:
    result.add("env-input:" & key & "=" & getEnv(key, ""))
  if taskArgs.len > 0:
    for i, arg in taskArgs:
      result.add("arg:" & $i & "=" & arg)
  for path in task.inputs:
    result.add("input-pattern:" & path)
  let inputs = expandPaths(projectDir, task.inputs)
  for file in inputs:
    if fileExists(file):
      result.add(relativePath(file, projectDir).replace("\\", "/") & ":" &
        hashFile(file))
  for path in task.outputs:
    result.add("output-pattern:" & path)
  if fileExists(projectDir / ConfigFileName):
    result.add("config:" & ConfigFileName & ":" &
      hashFile(projectDir / ConfigFileName))
  if fileExists(projectDir / LocalConfigFileName):
    result.add("config:" & LocalConfigFileName & ":" &
      hashFile(projectDir / LocalConfigFileName))
  let globalPath = globalConfigPath()
  if fileExists(globalPath):
    result.add("config:global:" & hashFile(globalPath))
  result.add("cache-read:" & $cfg.cache.read)
  result.add("cache-write:" & $cfg.cache.write)

proc taskCacheKey*(task: TaskInfo; projectDir, profile: string;
    cfg: BauConfig; selection: FeatureSelection = FeatureSelection();
    taskArgs: openArray[string] = []): string =
  ## Return the deterministic cache key for a task invocation.
  var content = "task:" & task.name & "\n"
  for input in taskCacheKeyInputs(task, projectDir, profile, cfg, selection,
      taskArgs):
    content.add(input & "\n")
  result = hashStr(content)

proc entryPath(root, taskName, key: string): string =
  root / "tasks" / taskName / key.replace(":", "-")

proc taskCacheEntry*(task: TaskInfo; projectDir: string; cfg: BauConfig;
    profile: string;
    selection: FeatureSelection = FeatureSelection();
    taskArgs: openArray[string] = []): TaskCacheEntry =
  ## Build the local cache entry descriptor for a task invocation.
  result.key = taskCacheKey(task, projectDir, profile, cfg, selection, taskArgs)
  result.taskName = task.name
  result.path = entryPath(cacheRoot(projectDir, cfg), task.name, result.key)
  result.outputs = task.outputs

proc cacheFilePath(entry: TaskCacheEntry; projectDir,
    outputPath: string): string =
  let absPath = if outputPath.isAbsolute: outputPath else: projectDir / outputPath
  let rel = relativePath(absPath, projectDir).replace("\\", "/")
  entry.path / "files" / rel

proc manifestPath(entry: TaskCacheEntry): string =
  entry.path / "manifest.json"

proc cacheEntryExists*(entry: TaskCacheEntry): bool =
  ## Return true when a local cache entry manifest exists.
  fileExists(manifestPath(entry))

proc outputRoots(projectDir: string; outputs: openArray[string]): seq[string] =
  for outputPath in outputs:
    let absPath = if outputPath.isAbsolute:
                    outputPath
                  else:
                    projectDir / outputPath
    result.add(normalizedPath(absolutePath(absPath)))

proc pathIsUnder(path, root: string): bool =
  let cleanPath = normalizedPath(absolutePath(path))
  let cleanRoot = normalizedPath(absolutePath(root))
  cleanPath == cleanRoot or cleanPath.startsWith(cleanRoot / "")

proc relPathIsSafe(path: string): bool =
  if path.len == 0 or path.isAbsolute:
    return false
  for part in path.replace("\\", "/").split("/"):
    if part.len == 0 or part == "." or part == "..":
      return false
  result = true

proc outputAllowed(projectDir: string; outputs: openArray[string];
    rel: string): bool =
  if not relPathIsSafe(rel):
    return false
  let absPath = normalizedPath(absolutePath(projectDir / rel))
  for root in outputRoots(projectDir, outputs):
    if pathIsUnder(absPath, root):
      return true

proc cacheLockPath(entry: TaskCacheEntry): string =
  entry.path & ".lock"

proc lockIsStale(path: string): bool =
  try:
    (getTime().toUnix - getLastModificationTime(path).toUnix) > 600
  except CatchableError:
    false

proc acquireCacheLock(entry: TaskCacheEntry): string =
  result = cacheLockPath(entry)
  createDir(parentDir(result))
  var waited = 0
  while true:
    try:
      if dirExists(result) and lockIsStale(result):
        removeDir(result)
      if not dirExists(result):
        createDir(result)
        saveFile(result / "owner", "pid=" & $getCurrentProcessId() & "\n")
        return
    except CatchableError:
      discard
    if waited >= CacheLockTimeoutMs:
      raise newException(IOError, "timed out waiting for task cache lock: " &
        result)
    sleep(25)
    waited += 25

proc releaseCacheLock(path: string) =
  if dirExists(path):
    removeDir(path)

template withCacheLock(entry: TaskCacheEntry; body: untyped) =
  let lockPath {.gensym.} = acquireCacheLock(entry)
  try:
    body
  finally:
    releaseCacheLock(lockPath)

proc uniqueWorkDir(parent, prefix: string): string =
  parent / (prefix & "-" & $getCurrentProcessId() & "-" &
    $getTime().toUnix & "-" & hashStr($epochTime()))

proc copyOutputToCache(entry: TaskCacheEntry; cacheDir, projectDir,
    outputPath: string) =
  let absPath = if outputPath.isAbsolute: outputPath else: projectDir / outputPath
  let cachePath = cacheDir / "files" /
    relativePath(absPath, projectDir).replace("\\", "/")
  if fileExists(absPath):
    createDir(parentDir(cachePath))
    copyFile(absPath, cachePath)
  elif dirExists(absPath):
    if dirExists(cachePath):
      removeDir(cachePath)
    createDir(parentDir(cachePath))
    copyDir(absPath, cachePath)

proc restoreOutputFromCache(entry: TaskCacheEntry; projectDir, outputPath,
    tempRoot: string) =
  let absPath = if outputPath.isAbsolute: outputPath else: projectDir / outputPath
  let rel = relativePath(absPath, projectDir).replace("\\", "/")
  if not outputAllowed(projectDir, entry.outputs, rel):
    raise newException(ValueError, "local cache path outside outputs: " & rel)
  let cachePath = cacheFilePath(entry, projectDir, outputPath)
  let tempPath = tempRoot / rel
  if fileExists(cachePath):
    if symlinkExists(absPath):
      raise newException(ValueError, "refusing to overwrite symlink: " & rel)
    createDir(parentDir(tempPath))
    copyFile(cachePath, tempPath)
    createDir(parentDir(absPath))
    if fileExists(absPath):
      removeFile(absPath)
    elif dirExists(absPath):
      removeDir(absPath)
    moveFile(tempPath, absPath)
  elif dirExists(cachePath):
    if symlinkExists(absPath):
      raise newException(ValueError, "refusing to overwrite symlink: " & rel)
    createDir(parentDir(tempPath))
    if dirExists(tempPath):
      removeDir(tempPath)
    copyDir(cachePath, tempPath)
    if dirExists(absPath):
      removeDir(absPath)
    elif fileExists(absPath):
      removeFile(absPath)
    createDir(parentDir(absPath))
    moveDir(tempPath, absPath)

proc saveTaskOutputs*(entry: TaskCacheEntry; task: TaskInfo;
    projectDir: string) =
  ## Save declared task outputs into a local cache entry.
  ##
  ## Writes are staged and moved into place under a cache lock.
  if task.outputs.len == 0:
    return
  withCacheLock(entry):
    let parent = parentDir(entry.path)
    createDir(parent)
    let tempDir = uniqueWorkDir(parent, "write")
    if dirExists(tempDir):
      removeDir(tempDir)
    createDir(tempDir)
    try:
      for outputPath in task.outputs:
        copyOutputToCache(entry, tempDir, projectDir, outputPath)
      let manifest = %*{
        "key": entry.key,
        "task": task.name,
        "outputs": task.outputs
      }
      saveFile(tempDir / "manifest.json", pretty(manifest))
      if dirExists(entry.path):
        removeDir(entry.path)
      moveDir(tempDir, entry.path)
    finally:
      if dirExists(tempDir):
        removeDir(tempDir)

proc restoreTaskOutputs*(entry: TaskCacheEntry; projectDir: string): bool =
  ## Restore declared task outputs from a local cache entry.
  ##
  ## Returns false when the entry is missing.
  withCacheLock(entry):
    if not cacheEntryExists(entry):
      return false
    let manifest = parseJson(readFileChecked(manifestPath(entry)))
    if manifest{"key"}.getStr("") != entry.key or
        manifest{"task"}.getStr("") != entry.taskName:
      raise newException(ValueError, "task cache manifest mismatch")
    let tempRoot = uniqueWorkDir(projectDir / BuildDirName / ".bau" /
      "local-restore" / entry.taskName, entry.key)
    if dirExists(tempRoot):
      removeDir(tempRoot)
    createDir(tempRoot)
    try:
      for outputNode in manifest["outputs"].getElems():
        restoreOutputFromCache(entry, projectDir, outputNode.getStr(),
          tempRoot)
      result = true
    finally:
      if dirExists(tempRoot):
        removeDir(tempRoot)

proc safeTaskName(name: string): string =
  name.replace("\\", "_").replace("/", "_").replace(" ", "_")

proc remoteRoot(cfg: BauConfig): string =
  result = cfg.cache.remote.strip()
  if result.startsWith("file://"):
    result = result["file://".len..^1]

proc remoteIsHttp(cfg: BauConfig): bool =
  cfg.cache.remote.startsWith("http://") or cfg.cache.remote.startsWith("https://")

proc remoteEntryPath(cfg: BauConfig; entry: TaskCacheEntry): string =
  remoteRoot(cfg) / "tasks" / safeTaskName(entry.taskName) /
    (entry.key & ".json")

proc remoteEntryUrl(cfg: BauConfig; entry: TaskCacheEntry): string =
  let base = cfg.cache.remote.strip(chars = {'/'})
  base & "/tasks/" & safeTaskName(entry.taskName) & "/" & entry.key & ".json"

proc addPayloadFile(files: JsonNode; projectDir, path: string) =
  let rel = relativePath(path, projectDir).replace("\\", "/")
  files.add(%*{
    "kind": "file",
    "path": rel,
    "hash": hashFile(path),
    "data": encode(readFileChecked(path))
  })

proc cachePayload(entry: TaskCacheEntry; task: TaskInfo;
    projectDir: string): JsonNode =
  var files = newJArray()
  for outputPath in task.outputs:
    let absPath = if outputPath.isAbsolute: outputPath else: projectDir / outputPath
    if fileExists(absPath):
      addPayloadFile(files, projectDir, absPath)
    elif dirExists(absPath):
      for file in walkDirRec(absPath, yieldFilter = {pcFile}):
        addPayloadFile(files, projectDir, file)
  result = %*{
    "version": RemotePayloadVersion,
    "task": task.name,
    "key": entry.key,
    "outputs": task.outputs,
    "files": files
  }

proc restorePayload(payload: JsonNode; entry: TaskCacheEntry;
    projectDir: string) =
  if payload{"version"}.getInt(0) != RemotePayloadVersion:
    raise newException(ValueError, "unsupported remote cache payload version")
  if payload{"task"}.getStr("") != entry.taskName:
    raise newException(ValueError, "remote cache task mismatch")
  if payload{"key"}.getStr("") != entry.key:
    raise newException(ValueError, "remote cache key mismatch")
  if not payload.hasKey("files") or payload["files"].kind != JArray:
    raise newException(ValueError, "remote cache payload missing files")

  let tempDir = projectDir / BuildDirName / ".bau" / "remote-restore" /
    entry.taskName / entry.key
  if dirExists(tempDir):
    removeDir(tempDir)
  createDir(tempDir)
  var restored: seq[string]
  try:
    for fileNode in payload["files"].getElems():
      if fileNode{"kind"}.getStr("") != "file":
        raise newException(ValueError, "unsupported remote cache file kind")
      let rel = fileNode{"path"}.getStr("")
      if not outputAllowed(projectDir, entry.outputs, rel):
        raise newException(ValueError, "remote cache path outside outputs: " & rel)
      let decoded = decode(fileNode["data"].getStr())
      let tempPath = tempDir / rel
      saveFile(tempPath, decoded)
      let expectedHash = fileNode{"hash"}.getStr("")
      if expectedHash.len > 0 and hashFile(tempPath) != expectedHash:
        raise newException(ValueError, "remote cache hash mismatch: " & rel)
      restored.add(rel)

    for rel in restored:
      let tempPath = tempDir / rel
      let destPath = projectDir / rel
      if symlinkExists(destPath):
        raise newException(ValueError, "refusing to overwrite symlink: " & rel)
      createDir(parentDir(destPath))
      copyFile(tempPath, destPath)
  finally:
    if dirExists(tempDir):
      removeDir(tempDir)

proc saveRemoteTaskOutputs*(entry: TaskCacheEntry; task: TaskInfo;
    projectDir: string; cfg: BauConfig): bool =
  ## Save declared task outputs to the configured remote cache.
  if cfg.cache.remote.len == 0 or task.outputs.len == 0:
    return false
  let payload = $cachePayload(entry, task, projectDir)
  if remoteIsHttp(cfg):
    var client = newHttpClient()
    try:
      let response = client.request(remoteEntryUrl(cfg, entry),
        httpMethod = HttpPut, body = payload)
      result = response.code.is2xx
    finally:
      client.close()
  else:
    saveFile(remoteEntryPath(cfg, entry), payload)
    result = true

proc restoreRemoteTaskOutputs*(entry: TaskCacheEntry; projectDir: string;
    cfg: BauConfig; remoteError: var string): bool =
  ## Restore task outputs from the configured remote cache.
  ##
  ## Returns false on miss or remote error and writes the error message to
  ## `remoteError`.
  if cfg.cache.remote.len == 0:
    return false
  try:
    var payloadText = ""
    if remoteIsHttp(cfg):
      var client = newHttpClient()
      try:
        payloadText = client.getContent(remoteEntryUrl(cfg, entry))
      finally:
        client.close()
    else:
      let path = remoteEntryPath(cfg, entry)
      if not fileExists(path):
        return false
      payloadText = readFileChecked(path)
    restorePayload(parseJson(payloadText), entry, projectDir)
    result = true
  except CatchableError as e:
    remoteError = e.msg
    result = false

proc listTaskCacheEntries*(projectDir: string; cfg: BauConfig): seq[string] =
  ## List local task-cache entry paths relative to the cache `tasks` root.
  let root = cacheRoot(projectDir, cfg) / "tasks"
  if not dirExists(root):
    return
  for kind, taskDir in walkDir(root):
    if kind == pcDir:
      for entryKind, entryDir in walkDir(taskDir):
        if entryKind == pcDir and fileExists(entryDir / "manifest.json"):
          result.add(relativePath(entryDir, root).replace("\\", "/"))
  result.sort()

proc cleanTaskCache*(projectDir: string; cfg: BauConfig) =
  ## Remove all local task-cache entries for a project.
  let root = cacheRoot(projectDir, cfg) / "tasks"
  if dirExists(root):
    removeDir(root)

proc explainTaskCache*(task: TaskInfo; projectDir: string; cfg: BauConfig;
    profile: string;
    selection: FeatureSelection = FeatureSelection()): TaskCacheExplain =
  ## Compute cache diagnostics for a task without restoring outputs.
  let entry = taskCacheEntry(task, projectDir, cfg, profile, selection)
  result.task = task.name
  result.key = entry.key
  result.path = entry.path
  result.localHit = cacheEntryExists(entry)
  result.outputs = task.outputs
  result.keyInputs = taskCacheKeyInputs(task, projectDir, profile, cfg, selection)
  var remoteError = ""
  if cfg.cache.remote.len > 0:
    if remoteIsHttp(cfg):
      var client = newHttpClient()
      try:
        let response = client.request(remoteEntryUrl(cfg, entry),
          httpMethod = HttpHead)
        result.remoteHit = response.code.is2xx
      except CatchableError as e:
        remoteError = e.msg
      finally:
        client.close()
    else:
      result.remoteHit = fileExists(remoteEntryPath(cfg, entry))
  result.remoteError = remoteError
