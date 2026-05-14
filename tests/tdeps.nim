import std/[options, os, tables, times]
import bau/[config, depscheck, features, lock]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc findPackage(lockFile: LockFile; name: string): Option[ResolvedPackage] =
  for pkg in lockFile.packages.values:
    if pkg.id.name == name:
      return some(pkg)
  none(ResolvedPackage)

block offline_dependency_material_check:
  let tmp = getTempDir() / "bau-test-offline-deps"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "vendor" / "shared" / "src" / "shared.nim", "discard\n")
  write(tmp / "bau.toml", """
[package]
name = "demo"

[dependencies]
shared = { path = "vendor/shared" }
sqlite = { version = ">=3.0", optional = true }

[features]
db = ["dep:sqlite"]
""")

  let cfg = parseBauConfigFile(tmp / "bau.toml")
  writeLockFile(generateLockFile(cfg, tmp), tmp / LockFileName)

  let selection = resolveFeatures(cfg, @[])
  let check = checkOfflineDependencies(cfg, tmp, selection)
  doAssert check.ok

  let dbSelection = resolveFeatures(cfg, @["db"])
  let missing = checkOfflineDependencies(cfg, tmp, dbSelection)
  doAssert not missing.ok

block dependency_policy_trusted_allowlist:
  var cfg = initBauConfig()
  cfg.deps["shared"] = DepInfo(version: some(">=1.0"))
  cfg.governance.trusted = @["other"]

  let tmp = getTempDir() / "bau-test-policy"
  if dirExists(tmp):
    removeDir(tmp)
  createDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)
  writeLockFile(generateLockFile(cfg, tmp), tmp / LockFileName)

  let check = checkDependencyPolicy(cfg, tmp)
  doAssert not check.ok

block lock_requires_material_for_nonoptional_registry_deps:
  let tmp = getTempDir() / "bau-test-lock-material"
  if dirExists(tmp):
    removeDir(tmp)
  createDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  var cfg = initBauConfig()
  cfg.deps["remote"] = DepInfo(version: some(">=1.0"))
  let lockFile = generateLockFile(cfg, tmp)
  doAssert unresolvedLockEntries(cfg, lockFile, tmp) == @["remote"]
  writeLockFile(lockFile, tmp / LockFileName)
  let report = validateLockFile(cfg, tmp, tmp / LockFileName)
  doAssert not report.ok
  doAssert report.diagnostics.len > 0
  doAssert report.diagnostics[0].kind == ldkUnmaterialized
  doAssert not lockIsValid(cfg, tmp / LockFileName, tmp)

block lock_records_resolved_material_and_release_age_is_enforced:
  let tmp = getTempDir() / "bau-test-lock-release-age"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "deps" / "remote" / "remote.nimble", """
version = "1.2.3"
""")
  write(tmp / "deps" / "remote" / "src" / "remote.nim", "const remote* = 1\n")
  var cfg = initBauConfig()
  cfg.deps["remote"] = DepInfo(version: some(">=1.0"))
  cfg.governance.minimumReleaseAgeHours = 24

  var lockFile = generateLockFile(cfg, tmp)
  writeLockFile(lockFile, tmp / LockFileName)
  doAssert lockIsValid(cfg, tmp / LockFileName, tmp)

  let remote = lockFile.findPackage("remote").get()
  doAssert remote.materialized
  doAssert remote.id.source == "registry+nimble://default"
  doAssert remote.id.version == "1.2.3"
  doAssert remote.lockedAt > 0

  let tooFresh = checkDependencyPolicy(cfg, tmp)
  doAssert not tooFresh.ok

  let remoteKey = remote.toString()
  lockFile.packages[remoteKey].lockedAt = int(getTime().toUnix) - (25 * 3600)
  writeLockFile(lockFile, tmp / LockFileName)
  let oldEnough = checkDependencyPolicy(cfg, tmp)
  doAssert oldEnough.ok

block lock_diagnostics_for_stale_and_checksum_mismatch:
  let tmp = getTempDir() / "bau-test-lock-diagnostics"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "deps" / "remote" / "remote.nimble", """
version = "1.2.3"
""")
  write(tmp / "deps" / "remote" / "src" / "remote.nim", "const remote* = 1\n")
  var cfg = initBauConfig()
  cfg.deps["remote"] = DepInfo(version: some(">=1.0"))

  let lockFile = generateLockFile(cfg, tmp)
  writeLockFile(lockFile, tmp / LockFileName)
  write(tmp / "deps" / "remote" / "src" / "remote.nim", "const remote* = 2\n")

  var report = validateLockFile(cfg, tmp, tmp / LockFileName)
  doAssert not report.ok
  doAssert report.diagnostics[0].kind == ldkChecksumMismatch

  cfg.deps["extra"] = DepInfo(version: some(">=1.0"))
  report = validateLockFile(cfg, tmp, tmp / LockFileName)
  var sawStale = false
  var sawMissing = false
  for diag in report.diagnostics:
    if diag.kind == ldkStaleRequirements:
      sawStale = true
    if diag.kind == ldkMissingDependency and diag.packageName == "extra":
      sawMissing = true
  doAssert sawStale
  doAssert sawMissing
