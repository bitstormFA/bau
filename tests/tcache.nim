import std/[base64, json, os, strutils, tables]
import bau/[argv, buildscript, config, features, taskcache]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block command_line_parser_honors_quotes:
  doAssert parseCommandLine("printf \"hello world\" 'again now'") ==
    @["printf", "hello world", "again now"]
  doAssert parseCommandLine("cmd one\\ two") == @["cmd", "one two"]
  try:
    discard parseCommandLine("cmd \"unterminated")
    doAssert false
  except ValueError:
    discard

block task_cache_key_includes_features:
  let tmp = getTempDir() / "bau-test-cache-key-features"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)
  write(tmp / "input.txt", "one\n")

  var cfg = initBauConfig()
  cfg.features["default"] = FeatureInfo(enables: @["docs"])
  cfg.features["docs"] = FeatureInfo()
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out.txt"])

  let base = taskCacheEntry(task, tmp, cfg, "dev", FeatureSelection())
  let withFeature = taskCacheEntry(task, tmp, cfg, "dev",
    resolveFeatures(cfg, @[]))
  doAssert base.key != withFeature.key

block task_cache_key_includes_declared_env_inputs:
  let tmp = getTempDir() / "bau-test-cache-key-env"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)
  write(tmp / "input.txt", "one\n")

  var cfg = initBauConfig()
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out.txt"],
    envInputs: @["BAU_TEST_CACHE_ENV"])

  putEnv("BAU_TEST_CACHE_ENV", "one")
  let first = taskCacheEntry(task, tmp, cfg, "dev")
  putEnv("BAU_TEST_CACHE_ENV", "two")
  let second = taskCacheEntry(task, tmp, cfg, "dev")
  delEnv("BAU_TEST_CACHE_ENV")
  doAssert first.key != second.key

block remote_file_task_cache_roundtrip:
  let tmp = getTempDir() / "bau-test-remote-task-cache"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "input.txt", "input\n")
  write(tmp / "out" / "result.txt", "result\n")

  var cfg = initBauConfig()
  cfg.cache.dir = tmp / ".local-cache"
  cfg.cache.remote = "file://" & (tmp / "remote-cache")
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out/result.txt"])
  let entry = taskCacheEntry(task, tmp, cfg, "dev")
  saveTaskOutputs(entry, task, tmp)
  doAssert saveRemoteTaskOutputs(entry, task, tmp, cfg)

  removeFile(tmp / "out" / "result.txt")
  cleanTaskCache(tmp, cfg)
  var remoteError = ""
  doAssert restoreRemoteTaskOutputs(entry, tmp, cfg, remoteError)
  doAssert remoteError.len == 0
  doAssert readFile(tmp / "out" / "result.txt") == "result\n"

block remote_cache_rejects_unsafe_payloads:
  let tmp = getTempDir() / "bau-test-remote-cache-safety"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "input.txt", "input\n")
  var cfg = initBauConfig()
  cfg.cache.remote = "file://" & (tmp / "remote-cache")
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out/result.txt"])
  let entry = taskCacheEntry(task, tmp, cfg, "dev")
  let remotePath = tmp / "remote-cache" / "tasks" / "gen" / (entry.key & ".json")

  write(remotePath, $(%*{
    "version": 1,
    "task": "gen",
    "key": entry.key,
    "outputs": task.outputs,
    "files": [
      {
        "kind": "file",
        "path": "../escape.txt",
        "hash": "",
        "data": encode("bad")
      }
    ]
  }))
  var remoteError = ""
  doAssert not restoreRemoteTaskOutputs(entry, tmp, cfg, remoteError)
  doAssert remoteError.contains("outside outputs")
  doAssert not fileExists(parentDir(tmp) / "escape.txt")

  write(remotePath, $(%*{
    "version": 1,
    "task": "gen",
    "key": entry.key,
    "outputs": task.outputs,
    "files": [
      {
        "kind": "file",
        "path": "out/result.txt",
        "hash": "not-the-hash",
        "data": encode("bad")
      }
    ]
  }))
  remoteError = ""
  doAssert not restoreRemoteTaskOutputs(entry, tmp, cfg, remoteError)
  doAssert remoteError.contains("hash mismatch")

block local_cache_rejects_tampered_manifest_paths:
  let tmp = getTempDir() / "bau-test-local-cache-safety"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "input.txt", "input\n")
  write(tmp / "out" / "result.txt", "result\n")

  var cfg = initBauConfig()
  cfg.cache.dir = tmp / ".local-cache"
  let task = TaskInfo(
    name: "gen",
    cmd: "echo gen",
    inputs: @["input.txt"],
    outputs: @["out/result.txt"])
  let entry = taskCacheEntry(task, tmp, cfg, "dev")
  saveTaskOutputs(entry, task, tmp)
  write(entry.path / "manifest.json", $(%*{
    "key": entry.key,
    "task": task.name,
    "outputs": ["../escape.txt"]
  }))
  write(entry.path / "files" / ".." / "escape.txt", "bad\n")
  try:
    discard restoreTaskOutputs(entry, tmp)
    doAssert false
  except ValueError:
    discard
  doAssert not fileExists(parentDir(tmp) / "escape.txt")

block build_script_rerun_directives_are_cached:
  let tmp = getTempDir() / "bau-test-buildscript-cache"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "input.txt", "input\n")
  write(tmp / "scripts" / "gen.sh", """
count=0
if [ -f count.txt ]; then
  count=$(cat count.txt)
fi
expr "$count" + 1 > count.txt
mkdir -p generated
echo generated > generated/out.nim
echo bau::rerun-if-changed=input.txt
echo bau::rerun-if-env-changed=GEN_MODE
echo bau::generated-file=generated/out.nim
echo bau::nim-flag=-d:generated
""")

  var cfg = initBauConfig()
  cfg.buildScripts.add(TaskInfo(name: "gen", cmd: "sh scripts/gen.sh"))
  let selection = FeatureSelection()

  let first = runBuildScripts(cfg, tmp, "dev", selection)
  doAssert first.flags == @["-d:generated"]
  doAssert readFile(tmp / "count.txt").strip() == "1"

  let second = runBuildScripts(cfg, tmp, "dev", selection)
  doAssert second.flags == @["-d:generated"]
  doAssert readFile(tmp / "count.txt").strip() == "1"

  removeFile(tmp / "generated" / "out.nim")
  discard runBuildScripts(cfg, tmp, "dev", selection)
  doAssert readFile(tmp / "count.txt").strip() == "2"

  write(tmp / "input.txt", "changed\n")
  discard runBuildScripts(cfg, tmp, "dev", selection)
  doAssert readFile(tmp / "count.txt").strip() == "3"
