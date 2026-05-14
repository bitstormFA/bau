## Validates dependency locks, checksums, and governance policy.

import std/[options, os, strutils, tables, times]
import bau/[config, features, lock]

type
  DependencyCheck* = object ## Dependency-policy or offline-readiness check result.
    ok*: bool ## True when no policy, lock, or materialization errors were found.
    messages*: seq[string] ## Human-readable check details and failures.

proc checkBlockedDeps(cfg: BauConfig; check: var DependencyCheck) =
  for name in cfg.governance.blocked:
    if cfg.deps.hasKey(name):
      check.ok = false
      check.messages.add("blocked dependency is present: " & name)

proc checkTrustedDeps(cfg: BauConfig; check: var DependencyCheck) =
  if cfg.governance.trusted.len > 0:
    for name in cfg.deps.keys:
      if name notin cfg.governance.trusted:
        check.ok = false
        check.messages.add("dependency is not in trusted allowlist: " & name)

proc verifyLockChecksums(cfg: BauConfig; projectDir, lockPath: string;
    check: var DependencyCheck) =
  let report = validateLockFile(cfg, projectDir, lockPath)
  if not report.ok:
    check.ok = false
    check.messages.add(report.messages)

proc directPackage(lockFile: LockFile; name: string): Option[ResolvedPackage] =
  for pkg in lockFile.packages.values:
    if pkg.direct and pkg.id.name == name:
      return some(pkg)
  none(ResolvedPackage)

proc checkMinimumReleaseAge(cfg: BauConfig; projectDir, lockPath: string;
    check: var DependencyCheck) =
  if cfg.governance.minimumReleaseAgeHours <= 0 or not fileExists(lockPath):
    return
  let lockFile = parseLockFile(lockPath)
  let nowUnix = int(getTime().toUnix)
  let minSeconds = cfg.governance.minimumReleaseAgeHours * 3600
  var enforced = false
  for name, dep in cfg.deps.pairs:
    if dep.path.isSome:
      continue
    let pkgOpt = directPackage(lockFile, name)
    if pkgOpt.isNone:
      continue
    enforced = true
    let pkg = pkgOpt.get()
    if pkg.id.source.startsWith("path+"):
      continue
    if not pkg.materialized:
      check.ok = false
      check.messages.add("minimumReleaseAgeHours cannot be enforced for " &
        name & ": dependency is not materialized in " & LockFileName)
    elif pkg.lockedAt <= 0:
      check.ok = false
      check.messages.add("minimumReleaseAgeHours cannot be enforced for " &
        name & ": lock entry has no lockedAt timestamp")
    elif nowUnix - pkg.lockedAt < minSeconds:
      let remaining = minSeconds - (nowUnix - pkg.lockedAt)
      check.ok = false
      check.messages.add("dependency locked too recently for " &
        "minimumReleaseAgeHours: " & name & " (" &
        $((remaining + 3599) div 3600) & " hour(s) remaining)")
  if enforced and check.ok:
    check.messages.add("minimumReleaseAgeHours enforced: " &
      $cfg.governance.minimumReleaseAgeHours & " hour(s)")

proc checkDependencyPolicy*(cfg: BauConfig; projectDir: string;
    lockPath: string = ""; workspaceRoot: string = ""): DependencyCheck =
  ## Validate dependency policy and lock integrity for a single project.
  result.ok = true
  checkBlockedDeps(cfg, result)
  checkTrustedDeps(cfg, result)
  let resolvedLockPath = if lockPath.len > 0: lockPath else:
                           projectDir / LockFileName
  let resolvedRoot = if workspaceRoot.len > 0: workspaceRoot else: projectDir
  verifyLockChecksums(cfg, resolvedRoot, resolvedLockPath, result)
  checkMinimumReleaseAge(cfg, resolvedRoot, resolvedLockPath, result)

proc checkDependencyPolicy*(projects: openArray[LockProject];
    workspaceRoot: string; lockPath: string): DependencyCheck =
  ## Validate dependency policy and lock integrity for workspace projects.
  result.ok = true
  for project in projects:
    checkBlockedDeps(project.cfg, result)
    checkTrustedDeps(project.cfg, result)
  let report = validateLockFile(projects, workspaceRoot, lockPath)
  if not report.ok:
    result.ok = false
    result.messages.add(report.messages)
  for project in projects:
    checkMinimumReleaseAge(project.cfg, workspaceRoot, lockPath, result)

proc dependencyMaterialPath(projectDir, name: string; dep: DepInfo): string =
  if dep.path.isSome:
    result = absolutePath(projectDir) / dep.path.get()
  else:
    result = projectDir / "deps" / name

proc checkOfflineDependencies*(cfg: BauConfig; projectDir: string;
    selection: FeatureSelection; lockPath: string = "";
    workspaceRoot: string = ""): DependencyCheck =
  ## Check that enabled dependencies are available without network access.
  result.ok = true
  let resolvedLockPath = if lockPath.len > 0: lockPath else:
                           projectDir / LockFileName
  let resolvedRoot = if workspaceRoot.len > 0: workspaceRoot else: projectDir
  let report = validateLockFile(cfg, resolvedRoot, resolvedLockPath)
  if not report.ok:
    result.ok = false
    result.messages.add(report.messages)
    return

  let lockFile = parseLockFile(resolvedLockPath)
  for name, dep in cfg.deps.pairs:
    if dependencyEnabled(cfg, name, dep, selection):
      let pkgOpt = directPackage(lockFile, name)
      let materialPath = if pkgOpt.isSome:
                           packageMaterialPath(resolvedRoot, pkgOpt.get())
                         else:
                           dependencyMaterialPath(projectDir, name, dep)
      if pkgOpt.isNone or (not fileExists(materialPath) and
          not dirExists(materialPath)):
        result.ok = false
        result.messages.add("dependency material unavailable offline: " & name)
      elif pkgOpt.isSome:
        let pkg = pkgOpt.get()
        if pkg.checksum.len > 0:
          let actual = checksumPath(materialPath)
          if actual != pkg.checksum:
            result.ok = false
            result.messages.add("checksum mismatch for " & name)

proc checkOfflineDependencies*(projects: openArray[LockProject];
    workspaceRoot: string; lockPath: string;
    selections: openArray[FeatureSelection]): DependencyCheck =
  ## Check offline dependency availability for a workspace.
  result.ok = true
  let report = validateLockFile(projects, workspaceRoot, lockPath)
  if not report.ok:
    result.ok = false
    result.messages.add(report.messages)
    return
  let lockFile = parseLockFile(lockPath)
  for idx, project in projects:
    let selection = if idx < selections.len: selections[idx] else:
                      FeatureSelection()
    for name, dep in project.cfg.deps.pairs:
      if dependencyEnabled(project.cfg, name, dep, selection):
        let pkgOpt = directPackage(lockFile, name)
        let materialPath = if pkgOpt.isSome:
                             packageMaterialPath(workspaceRoot, pkgOpt.get())
                           else:
                             dependencyMaterialPath(project.projectDir, name, dep)
        if pkgOpt.isNone or (not fileExists(materialPath) and
            not dirExists(materialPath)):
          result.ok = false
          result.messages.add(project.path &
            ": dependency material unavailable offline: " & name)
        elif pkgOpt.isSome:
          let pkg = pkgOpt.get()
          if pkg.checksum.len > 0 and checksumPath(materialPath) != pkg.checksum:
            result.ok = false
            result.messages.add(project.path & ": checksum mismatch for " & name)
