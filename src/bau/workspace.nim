## Loads workspace members and merges workspace defaults.

import std/[algorithm, options, os, strutils]
import bau/[config, util]

type
  WorkspaceScope* = enum ## Selection mode for workspace member loading.
    wsDefaultMembers ## Load default members when configured.
    wsAllMembers ## Load every configured workspace member.

  WorkspaceMember* = object ## Resolved workspace member path and display name.
    path*: string ## Member path relative to the workspace root.
    projectDir*: string ## Absolute project directory for the member.
    name*: string ## Package name or directory-derived fallback.

  WorkspaceProject* = object ## Workspace member plus its effective config.
    path*: string ## Member path relative to the workspace root.
    projectDir*: string ## Absolute project directory for the member.
    name*: string ## Package name or directory-derived fallback.
    cfg*: BauConfig ## Effective Bau configuration for this member.

proc normalizeRel(path: string): string =
  path.replace("\\", "/").strip(chars = {'/'})

proc hasPatternChars(path: string): bool =
  path.contains("*") or path.contains("?") or path.contains("[")

proc addMemberPath(paths: var seq[string]; root, path: string) =
  let absPath = if path.isAbsolute: path else: root / path
  if hasPatternChars(path):
    for candidate in walkPattern(absPath):
      if dirExists(candidate) and fileExists(candidate / ConfigFileName):
        paths.add(normalizeRel(relativePath(candidate, root)))
  elif dirExists(absPath) and fileExists(absPath / ConfigFileName):
    paths.add(normalizeRel(relativePath(absPath, root)))

proc expandMemberPaths(root: string; patterns: openArray[string]): seq[string] =
  for pattern in patterns:
    result.addMemberPath(root, pattern)
  result.sort()
  var unique: seq[string]
  for path in result:
    if path notin unique:
      unique.add(path)
  result = unique

proc matchesWorkspacePattern(root, path, pattern: string): bool =
  let cleanPath = normalizeRel(path)
  let cleanPattern = normalizeRel(pattern)
  if hasPatternChars(cleanPattern):
    let absPattern = root / cleanPattern
    for candidate in walkPattern(absPattern):
      let rel = normalizeRel(relativePath(candidate, root))
      if rel == cleanPath or cleanPath.startsWith(rel & "/"):
        return true
  result = cleanPath == cleanPattern or cleanPath.startsWith(cleanPattern & "/")

proc excluded(root, path: string; patterns: openArray[string]): bool =
  for pattern in patterns:
    if matchesWorkspacePattern(root, path, pattern):
      return true

proc resolveWorkspaceMemberPaths*(root: string; ws: WorkspaceConfig;
    defaultOnly = true): seq[string] =
  ## Resolve member path patterns into sorted relative project paths.
  let requested = if defaultOnly and ws.defaultMembers.len > 0:
                    ws.defaultMembers
                  else:
                    ws.members
  for path in expandMemberPaths(root, requested):
    if not excluded(root, path, ws.exclude):
      result.add(path)
  result.sort()
  var unique: seq[string]
  for path in result:
    if path notin unique:
      unique.add(path)
  result = unique

proc resolveWorkspaceMembers*(root: string; ws: WorkspaceConfig;
    defaultOnly = true): seq[WorkspaceMember] =
  ## Resolve configured workspace members and infer display names.
  for path in resolveWorkspaceMemberPaths(root, ws, defaultOnly):
    let projectDir = absolutePath(root / path)
    var name = extractFilename(projectDir)
    try:
      let cfg = parseBauConfigFile(projectDir / ConfigFileName)
      if cfg.package.name.len > 0:
        name = cfg.package.name
    except CatchableError:
      discard
    result.add(WorkspaceMember(path: path, projectDir: projectDir, name: name))

proc isWorkspaceRoot*(projectDir: string): bool =
  ## Return true when `projectDir` contains a `[workspace]` config table.
  loadWorkspaceConfig(projectDir / ConfigFileName).isSome

proc loadWorkspaceProjects*(root: string;
    scope: WorkspaceScope = wsDefaultMembers): seq[WorkspaceProject] =
  ## Load effective configs for the selected projects in a workspace.
  ##
  ## When `root` is not a workspace, it is returned as a single project.
  let wsOpt = loadWorkspaceConfig(root / ConfigFileName)
  if wsOpt.isNone:
    let cfg = loadEffectiveConfig(root)
    let name = if cfg.package.name.len > 0: cfg.package.name else:
                 extractFilename(root)
    return @[WorkspaceProject(path: ".", projectDir: root, name: name, cfg: cfg)]

  let ws = wsOpt.get()
  let defaultOnly = scope == wsDefaultMembers
  for member in resolveWorkspaceMembers(root, ws, defaultOnly):
    let cfg = loadEffectiveConfig(member.projectDir, root)
    let name = if cfg.package.name.len > 0: cfg.package.name else: member.name
    result.add(WorkspaceProject(path: member.path,
      projectDir: member.projectDir,
      name: name, cfg: cfg))
