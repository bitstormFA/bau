import std/[os, options]
import bau/build
import bau/fingerprint

block fingerprint_equality:
  let fp1 = computeFingerprint(["a.nim"], ["--opt:speed"], "dev")
  let fp2 = computeFingerprint(["a.nim"], ["--opt:speed"], "dev")
  doAssert fp1 == fp2

block fingerprint_different_profile:
  let fp1 = computeFingerprint(["a.nim"], ["--opt:speed"], "dev")
  let fp2 = computeFingerprint(["a.nim"], ["--opt:speed"], "release")
  doAssert fp1 != fp2

block fingerprint_different_flags:
  let fp1 = computeFingerprint(["a.nim"], ["--opt:speed"], "dev")
  let fp2 = computeFingerprint(["a.nim"], ["--opt:none"], "dev")
  doAssert fp1 != fp2

block fingerprint_inputs_capture_env_and_missing_paths:
  let fp1 = computeFingerprint(initFingerprintInputs(["missing-a.nim"],
    ["--opt:speed"], "dev", envInputs = ["BAU_MODE=one"]))
  let fp2 = computeFingerprint(initFingerprintInputs(["missing-a.nim"],
    ["--opt:speed"], "dev", envInputs = ["BAU_MODE=two"]))
  let fp3 = computeFingerprint(initFingerprintInputs(["missing-b.nim"],
    ["--opt:speed"], "dev", envInputs = ["BAU_MODE=one"]))
  doAssert fp1 != fp2
  doAssert fp1 != fp3

block fingerprint_inputs_normalize_source_paths:
  let tmp = getTempDir() / "bau-test-fp-normalize"
  if dirExists(tmp):
    removeDir(tmp)
  createDir(tmp / "src")
  defer:
    if dirExists(tmp):
      removeDir(tmp)
  writeFile(tmp / "src" / "demo.nim", "const demo* = 1\n")
  let direct = computeFingerprint(initFingerprintInputs(
    [tmp / "src" / "demo.nim"], ["--hints:off"], "dev"))
  let dotted = computeFingerprint(initFingerprintInputs(
    [tmp / "src" / ".." / "src" / "demo.nim"], ["--hints:off"], "dev"))
  doAssert direct == dotted

block fingerprint_ignores_source_mtime_when_content_is_same:
  let tmp = getTempDir() / "bau-test-fp-mtime"
  if dirExists(tmp):
    removeDir(tmp)
  createDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  let source = tmp / "demo.nim"
  writeFile(source, "const demo* = 1\n")
  let first = computeFingerprint([source], ["--hints:off"], "dev")
  sleep(1100)
  writeFile(source, "const demo* = 1\n")
  let second = computeFingerprint([source], ["--hints:off"], "dev")
  doAssert first.sourceHash == second.sourceHash
  doAssert first == second

block fingerprint_env_inputs_ignore_volatile_runtime_env:
  let oldPath = getEnv("PATH", "")
  let oldJobs = getEnv("BAU_JOBS", "")
  let oldColor = getEnv("BAU_COLOR", "")
  let hadPath = existsEnv("PATH")
  let hadJobs = existsEnv("BAU_JOBS")
  let hadColor = existsEnv("BAU_COLOR")
  defer:
    if hadPath: putEnv("PATH", oldPath) else: delEnv("PATH")
    if hadJobs: putEnv("BAU_JOBS", oldJobs) else: delEnv("BAU_JOBS")
    if hadColor: putEnv("BAU_COLOR", oldColor) else: delEnv("BAU_COLOR")

  putEnv("PATH", "/tmp/bau-test-path")
  putEnv("BAU_JOBS", "32")
  putEnv("BAU_COLOR", "always")
  let inputs = collectFingerprintEnvInputs()
  doAssert "PATH=/tmp/bau-test-path" notin inputs
  doAssert "BAU_JOBS=32" notin inputs
  doAssert "BAU_COLOR=always" notin inputs

block fingerprint_json_roundtrip:
  let fp = computeFingerprint(["x.nim", "y.nim"], ["-d:foo"], "test")
  let json = toJson(fp)
  let fp2 = fromJson(json)
  doAssert fp == fp2

block fingerprint_save_and_load:
  let tmpDir = getTempDir() / "bau-test-fp"
  createDir(tmpDir)
  defer: removeDir(tmpDir)
  let fpDir = tmpDir / "fps"
  let fp = computeFingerprint(["test.nim"], ["--debugInfo:on"], "dev")
  saveFingerprint(fpDir, "myapp", "main", fp)
  let loaded = loadFingerprint(fpDir, "myapp", "main")
  doAssert isSome(loaded)
  doAssert get(loaded) == fp

block fingerprint_load_missing:
  let loaded = loadFingerprint("/nonexistent/path", "notthere", "main")
  doAssert not isSome(loaded)

block fingerprint_remove:
  let tmpDir = getTempDir() / "bau-test-fp-remove"
  createDir(tmpDir)
  defer: removeDir(tmpDir)
  let fpDir = tmpDir / "fps"
  let fp = computeFingerprint(["test.nim"], ["--debugInfo:on"], "dev")
  saveFingerprint(fpDir, "myapp", "main", fp)
  removeFingerprint(fpDir, "myapp", "main")
  let loaded = loadFingerprint(fpDir, "myapp", "main")
  doAssert not isSome(loaded)
