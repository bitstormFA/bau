import std/[json, options, os, strutils, tables]
import bau/[command, config, lock, ops, workspace]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

block workspace_members_globs_defaults_and_excludes:
  let tmp = getTempDir() / "bau-test-workspace-members"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[workspace]
members = ["apps/*", "tools/*"]
defaultMembers = ["apps/*"]
exclude = ["apps/skip"]
""")
  write(tmp / "apps" / "one" / "bau.toml", """
[package]
name = "one"

[build]
source = "src"
""")
  write(tmp / "apps" / "one" / "src" / "tool.nim", """
when isMainModule:
  echo "tool"
""")
  write(tmp / "apps" / "skip" / "bau.toml", """
[package]
name = "skip"
""")
  write(tmp / "tools" / "tool" / "bau.toml", """
[package]
name = "tool"
""")

  let ws = get(loadWorkspaceConfig(tmp / "bau.toml"))
  let defaults = resolveWorkspaceMemberPaths(tmp, ws)
  doAssert defaults == @["apps/one"]

  let all = resolveWorkspaceMemberPaths(tmp, ws, defaultOnly = false)
  doAssert all == @["apps/one", "tools/tool"]

  let members = resolveWorkspaceMembers(tmp, ws, defaultOnly = false)
  doAssert members.len == 2
  doAssert members[0].name == "one"
  doAssert members[1].name == "tool"

  let projects = loadWorkspaceProjects(tmp, wsAllMembers)
  doAssert projects.len == 2
  doAssert projects[0].cfg.package.name == "one"
  doAssert projects[1].cfg.package.name == "tool"

  let meta = metadataOperation(tmp).json
  doAssert meta["workspace"].getBool()
  doAssert meta["members"].getElems().len == 1
  doAssert meta["members"][0]["path"].getStr() == "apps/one"

  let graph = graphOperation(tmp).json
  doAssert graph["workspace"].getBool()
  doAssert graph["members"].getElems().len == 1

  let oldDir = getCurrentDir()
  setCurrentDir(tmp)
  try:
    tailorCommand(parseCliOptions(@["tailor", "--write"]))
  finally:
    setCurrentDir(oldDir)
  doAssert readFile(tmp / "apps" / "one" / "bau.toml").contains("main = \"src/tool.nim\"")

block workspace_uses_single_root_lock_graph:
  let tmp = getTempDir() / "bau-test-workspace-root-lock"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "bau.toml", """
[workspace]
members = ["apps/*"]
defaultMembers = ["apps/*"]
""")
  write(tmp / "apps" / "one" / "bau.toml", """
[package]
name = "one"

[dependencies]
shared = ">=1.0"
""")
  write(tmp / "apps" / "two" / "bau.toml", """
[package]
name = "two"

[dependencies]
shared = ">=1.0"
""")
  write(tmp / "apps" / "one" / "deps" / "shared" / "shared.nimble",
    "version = \"1.0.0\"\n")
  write(tmp / "apps" / "one" / "deps" / "shared" / "src" / "shared.nim",
    "const shared* = 1\n")
  write(tmp / "apps" / "two" / "deps" / "shared" / "shared.nimble",
    "version = \"1.0.0\"\n")
  write(tmp / "apps" / "two" / "deps" / "shared" / "src" / "shared.nim",
    "const shared* = 1\n")

  let projects = loadWorkspaceProjects(tmp, wsAllMembers)
  var lockProjects: seq[LockProject]
  for project in projects:
    lockProjects.add(LockProject(path: project.path,
      projectDir: project.projectDir, cfg: project.cfg))
  let lockFile = generateLockFile(lockProjects, tmp)
  writeLockFile(lockFile, tmp / LockFileName)

  doAssert fileExists(tmp / LockFileName)
  doAssert not fileExists(tmp / "apps" / "one" / LockFileName)
  doAssert lockFile.workspaceMembers == @["apps/one", "apps/two"]
  doAssert lockIsValid(lockProjects, tmp, tmp / LockFileName)
  doAssert lockFile.packages.len == 1
