## Reads, writes, and verifies reproducible Bau dependency lockfiles.

import std/[algorithm, json, options, os, sequtils, sets, strutils, tables, times]
import parsetoml
import bau/[util, config]

type
  SourceKind* = enum ## Dependency source category encoded into lock metadata.
    skRegistry = "registry" ## Registry source such as Nimble.
    skGit = "git" ## Git source.
    skPath = "path" ## Local path dependency.
    skVendor = "vendor" ## Vendor directory source.
    skMirror = "mirror" ## Local registry or mirror source.

  SourceId* = object ## Stable source identity used in lock entries.
    uri*: string ## Canonical URI including source kind prefix.

  PackageId* = object ## Identity of one resolved package.
    name*: string ## Package name.
    version*: string ## Resolved package version.
    source*: string ## Canonical source URI.

  DependencyReq* = object ## Root dependency requirement captured in a lockfile.
    name*: string ## Dependency name from configuration.
    requirement*: string ## Version requirement, if any.
    source*: string ## Canonical source URI.
    registry*: string ## Configured source or registry name.
    url*: string ## Git URL, if configured.
    path*: string ## Local path, if configured.
    tag*: string ## Git tag, if configured.
    branch*: string ## Git branch, if configured.
    rev*: string ## Exact Git revision, if configured.
    optional*: bool ## Whether the dependency is optional.
    enabledBy*: seq[string] ## Features that can enable this dependency.
    workspaceMember*: string ## Workspace member that declared the requirement.

  DependencyEdge* = object ## Dependency edge from one package to another.
    name*: string ## Required dependency name.
    requirement*: string ## Required version expression.
    package*: string ## Resolved package key, when known.
    optional*: bool ## Whether the edge is optional.

  ResolvedPackage* = object ## Fully or partially resolved package lock entry.
    id*: PackageId ## Package identity.
    dependencies*: seq[DependencyEdge] ## Dependencies declared by the package.
    revision*: string ## Git revision, when available.
    checksum*: string ## Content checksum for materialized package files.
    path*: string ## Workspace-relative materialized path.
    direct*: bool ## True when declared directly by a workspace member.
    optional*: bool ## True when all direct requirements are optional.
    enabledBy*: seq[string] ## Features that enable this package.
    materialized*: bool ## True when package files were present locally.
    lockedAt*: int ## Unix timestamp when the materialized package was locked.

  ResolveGraph* = object ## In-memory dependency graph before lockfile emission.
    resolver*: string ## Resolver implementation name.
    requirementsHash*: string ## Hash of root dependency requirements.
    workspaceMembers*: seq[string] ## Workspace members included in the graph.
    rootDependencies*: seq[DependencyReq] ## Direct requirements from projects.
    packages*: OrderedTable[string, ResolvedPackage] ## Resolved packages keyed by identity string.

  LockFile* = object ## Parsed or generated Bau lockfile content.
    version*: int ## Lockfile format version.
    resolver*: string ## Resolver implementation that produced the lock.
    requirementsHash*: string ## Hash of root dependency requirements.
    workspaceMembers*: seq[string] ## Workspace members covered by the lock.
    rootDependencies*: seq[DependencyReq] ## Direct requirements captured in the lock.
    packages*: OrderedTable[string, ResolvedPackage] ## Locked packages keyed by identity string.

  LockDiagnosticKind* = enum ## Machine-readable lock validation issue kind.
    ldkMissingLock = "missing-lock" ## Lockfile is absent.
    ldkInvalidLock = "invalid-lock" ## Lockfile cannot be parsed or has wrong version.
    ldkStaleRequirements = "stale-requirements" ## Configuration no longer matches lock requirements.
    ldkMissingDependency = "missing-dependency" ## Required direct dependency is absent from the lock.
    ldkMissingMaterial = "missing-material" ## Locked materialized files are missing.
    ldkChecksumMismatch = "checksum-mismatch" ## Materialized files do not match the lock checksum.
    ldkRevisionMismatch = "revision-mismatch" ## Materialized Git revision differs from the lock.
    ldkUnmaterialized = "unmaterialized" ## Required direct dependency was not materialized.

  LockDiagnostic* = object ## One lock validation diagnostic.
    kind*: LockDiagnosticKind ## Stable diagnostic kind.
    packageName*: string ## Related package name, when applicable.
    path*: string ## Related file or directory path.
    message*: string ## Human-readable diagnostic message.

  LockValidationReport* = object ## Result of validating a Bau lockfile.
    ok*: bool ## True when no diagnostics were produced.
    messages*: seq[string] ## Human-readable diagnostic messages.
    diagnostics*: seq[LockDiagnostic] ## Structured diagnostics.

  SourceProvider* = object ## Resolved source definition used to identify packages.
    name*: string ## Source name from configuration.
    kind*: SourceKind ## Source category.
    uri*: string ## Canonical source URI.
    replaceWith*: string ## Replacement source name, if configured.

  LockProject* = object ## Workspace project included in lock generation.
    path*: string ## Project path relative to the workspace root.
    projectDir*: string ## Absolute project directory.
    cfg*: BauConfig ## Effective project configuration.

  AtlasBridgeEntry = object
    dir: string
    url: string
    commit: string
    version: string

const
  LockFileName* = "bau.lock" ## Filename used for Bau dependency locks.
  LockFileVersion* = 2 ## Current lockfile format version.
  DefaultResolver* = "atlas-bridge" ## Default resolver identifier written to locks.

proc initLockFile*(): LockFile =
  ## Return an empty lockfile using the current format version.
  LockFile(
    version: LockFileVersion,
    resolver: DefaultResolver,
    packages: initOrderedTable[string, ResolvedPackage]())

proc initResolveGraph*(): ResolveGraph =
  ## Return an empty dependency resolution graph.
  ResolveGraph(
    resolver: DefaultResolver,
    packages: initOrderedTable[string, ResolvedPackage]())

proc toString*(id: PackageId): string =
  ## Format a package identity as the stable lock-table key.
  id.name & " " & id.version & " (" & id.source & ")"

proc toString*(pkg: ResolvedPackage): string =
  ## Format a resolved package identity as the stable lock-table key.
  pkg.id.toString()

proc materialExists(path: string): bool
proc checksumPath*(path: string): string
proc gitRevision*(path: string): string

proc lockIdentity*(provider: SourceProvider; dep: DepInfo): SourceId =
  ## Build the canonical source identity for a dependency and provider.
  if provider.replaceWith.len > 0:
    result.uri = provider.replaceWith
  elif provider.uri.len > 0:
    result.uri = provider.uri
  elif dep.path.isSome:
    result.uri = "path+" & dep.path.get()
  elif dep.url.isSome:
    result.uri = "git+" & dep.url.get()
  else:
    result.uri = "registry+nimble://default"

proc sortedKeys[T](table: Table[string, T]): seq[string] =
  for key in table.keys:
    result.add(key)
  result.sort()

proc sortedOrderedKeys[T](table: OrderedTable[string, T]): seq[string] =
  for key in table.keys:
    result.add(key)
  result.sort()

proc addUnique(items: var seq[string]; item: string) =
  if item.len > 0 and item notin items:
    items.add(item)

proc norm(path: string): string =
  path.replace("\\", "/")

proc relTo(root, path: string): string =
  result = relativePath(path, root).norm()
  if result == ".":
    result = ""

proc materialExists(path: string): bool =
  path.len > 0 and (fileExists(path) or dirExists(path))

proc checksumPath*(path: string): string =
  ## Compute a deterministic checksum for a file or directory tree.
  ##
  ## Directory checksums skip common build and VCS artifacts.
  if fileExists(path):
    return hashFile(path)
  if not dirExists(path):
    return ""

  var files: seq[string]
  for f in walkDirRec(path, yieldFilter = {pcFile}):
    let rel = relativePath(f, path).norm()
    if rel.startsWith(".git/") or rel.contains("/.git/") or
        rel.startsWith("build/") or rel.contains("/build/") or
        rel.startsWith("nimcache/") or rel.contains("/nimcache/"):
      discard
    else:
      files.add(f)
  files.sort()

  var content = ""
  for f in files:
    let rel = relativePath(f, path).norm()
    content.add(rel & ":" & hashFile(f) & "\n")
  result = hashStr(content)

proc gitRevision*(path: string): string =
  ## Return the current Git revision for a repository path, or an empty string.
  if not dirExists(path / ".git"):
    return ""
  let (exitCode, output) = runCmd("git", ["-C", path, "rev-parse", "HEAD"])
  if exitCode == 0:
    result = output.strip()

proc gitOrigin(path: string): string =
  if not dirExists(path / ".git"):
    return ""
  let (exitCode, output) = runCmd("git", ["-C", path, "config", "--get",
    "remote.origin.url"])
  if exitCode == 0:
    result = output.strip()

proc sourceProvider*(name: string; info: SourceInfo): SourceProvider =
  ## Convert configured source info into a source provider descriptor.
  result.name = name
  result.replaceWith = info.replaceWith
  if info.directory.len > 0:
    result.kind = skVendor
    result.uri = "vendor+" & info.directory.norm()
  elif info.localRegistry.len > 0:
    result.kind = skMirror
    result.uri = "mirror+" & info.localRegistry.norm()
  elif info.git.len > 0:
    result.kind = skGit
    result.uri = "git+" & info.git
  elif info.registry.len > 0:
    result.kind = skRegistry
    if info.registry.contains("://"):
      result.uri = "registry+" & info.registry
    else:
      result.uri = "registry+nimble://" & info.registry
  else:
    result.kind = skRegistry
    result.uri = "registry+nimble://" & name

proc defaultSourceProvider(name: string): SourceProvider =
  SourceProvider(name: name, kind: skRegistry,
    uri: "registry+nimble://" & name)

proc resolvedSourceProvider(sources: Table[string, SourceInfo];
    name: string): SourceProvider =
  if sources.hasKey(name):
    result = sourceProvider(name, sources[name])
  else:
    result = defaultSourceProvider(name)

  var seen = initHashSet[string]()
  seen.incl(name)
  while result.replaceWith.len > 0 and
      sources.hasKey(result.replaceWith) and
      result.replaceWith notin seen:
    let nextName = result.replaceWith
    seen.incl(nextName)
    result = sourceProvider(nextName, sources[nextName])

proc dependencyProvider(cfg: BauConfig; dep: DepInfo): SourceProvider =
  resolvedSourceProvider(cfg.sources, dep.registry.get("default"))

proc sourceMaterialRoot(provider: SourceProvider; projectDir: string): string =
  case provider.kind
  of skVendor:
    if provider.uri.startsWith("vendor+"):
      result = provider.uri["vendor+".len..^1]
  of skMirror:
    if provider.uri.startsWith("mirror+"):
      result = provider.uri["mirror+".len..^1]
  else:
    discard
  if result.len > 0 and not result.isAbsolute:
    result = projectDir / result

proc depSourceUri(dep: DepInfo; project: LockProject; workspaceRoot,
    name: string; materialPath = ""; resolvedRev = ""): string =
  if dep.path.isSome:
    let absPath = absolutePath(project.projectDir / dep.path.get())
    return "path+" & relTo(workspaceRoot, absPath)
  if dep.url.isSome:
    let rev = if resolvedRev.len > 0: resolvedRev
              elif dep.rev.isSome: dep.rev.get()
              elif materialPath.len > 0: gitRevision(materialPath)
              elif dep.tag.isSome: "tag:" & dep.tag.get()
              elif dep.branch.isSome: "branch:" & dep.branch.get()
              else: ""
    result = "git+" & dep.url.get()
    if rev.len > 0:
      result.add("#" & rev)
    return
  dependencyProvider(project.cfg, dep).lockIdentity(dep).uri

proc dependencyMaterialPath(projectDir, name: string; dep: DepInfo;
    cfg: BauConfig): string =
  if dep.path.isSome:
    absolutePath(projectDir / dep.path.get())
  else:
    let provider = dependencyProvider(cfg, dep)
    let root = sourceMaterialRoot(provider, projectDir)
    if root.len > 0:
      root / name
    else:
      projectDir / "deps" / name

proc findNimbleFiles(path: string; preferredName = ""): seq[string] =
  let preferred = path / (preferredName & ".nimble")
  if preferredName.len > 0 and fileExists(preferred):
    result.add(preferred)
  if dirExists(path):
    for file in walkFiles(path / "*.nimble"):
      if file notin result:
        result.add(file)
  result.sort()

proc stripQuotedValue(value: string): string =
  result = value.strip()
  if result.len >= 2 and ((result[0] == '"' and result[^1] == '"') or
      (result[0] == '\'' and result[^1] == '\'')):
    result = result[1..^2]

proc readNimbleVersion*(depPath, name: string): string =
  ## Read a dependency version from a `.nimble` file when available.
  for file in findNimbleFiles(depPath, name):
    for line in readFileChecked(file).splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("version") and trimmed.contains("="):
        let parts = trimmed.split("=", 1)
        if parts.len == 2:
          return stripQuotedValue(parts[1])

proc readNimblePackageName(depPath, fallback: string): string =
  for file in findNimbleFiles(depPath, fallback):
    for line in readFileChecked(file).splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("name") and trimmed.contains("="):
        let parts = trimmed.split("=", 1)
        if parts.len == 2:
          let name = stripQuotedValue(parts[1])
          if name.len > 0:
            return name
    let base = file.extractFilename().replace(".nimble", "")
    if base.len > 0:
      return base
  result = fallback

proc quotedParts(line: string): seq[string] =
  var inQuote = false
  var quote = '\0'
  var current = ""
  for ch in line:
    if inQuote:
      if ch == quote:
        result.add(current)
        current = ""
        inQuote = false
      else:
        current.add(ch)
    elif ch == '"' or ch == '\'':
      inQuote = true
      quote = ch

proc parseRequiresItem(item: string): DependencyEdge =
  let parts = item.strip().splitWhitespace()
  if parts.len > 0:
    result.name = parts[0]
  if parts.len > 1:
    result.requirement = parts[1..^1].join(" ")

proc readNimbleDependencies(depPath, depName: string): seq[DependencyEdge] =
  for file in findNimbleFiles(depPath, depName):
    for line in readFileChecked(file).splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("requires"):
        for item in quotedParts(trimmed):
          var edge = parseRequiresItem(item)
          if edge.name.len > 0 and edge.name != "nim":
            result.add(edge)

proc featureEnablers(cfg: BauConfig; depName: string): seq[string] =
  for feature in sortedKeys(cfg.features):
    for item in cfg.features[feature].enables:
      if item == depName or item == "dep:" & depName:
        result.addUnique(feature)

proc depReq(name: string; dep: DepInfo; project: LockProject;
    workspaceRoot: string): DependencyReq =
  result.name = name
  result.requirement = dep.version.get("")
  result.registry = dep.registry.get("")
  result.url = dep.url.get("")
  result.path = dep.path.get("")
  result.tag = dep.tag.get("")
  result.branch = dep.branch.get("")
  result.rev = dep.rev.get("")
  result.optional = dep.optional
  result.enabledBy = featureEnablers(project.cfg, name)
  result.workspaceMember = project.path
  result.source = depSourceUri(dep, project, workspaceRoot, name)

proc reqLine(req: DependencyReq): string =
  req.workspaceMember & "|" & req.name & "|" & req.requirement & "|" &
    req.source & "|" & req.registry & "|" & req.url & "|" & req.path & "|" &
    req.tag & "|" & req.branch & "|" & req.rev & "|" & $req.optional & "|" &
    req.enabledBy.join(",")

proc depLine(name: string; dep: DepInfo): string =
  name & "|" & dep.version.get("") & "|" & dep.registry.get("") & "|" &
    dep.url.get("") & "|" & dep.path.get("") & "|" & dep.tag.get("") & "|" &
    dep.branch.get("") & "|" & dep.rev.get("") & "|" & $dep.optional

proc sourceLine(name: string; source: SourceInfo): string =
  name & "|" & source.registry & "|" & source.directory & "|" &
    source.localRegistry & "|" & source.git & "|" & source.replaceWith

proc requirementsHash*(projects: openArray[LockProject];
    workspaceRoot: string): string =
  ## Hash dependency requirements that should invalidate a lock when changed.
  var lines: seq[string]
  lines.add("workspaceRoot=" & absolutePath(workspaceRoot).norm())
  for project in projects:
    lines.add("member=" & project.path & "|" & project.cfg.package.name)
    for name in sortedKeys(project.cfg.deps):
      lines.add("dep=" & project.path & "|" & depLine(name, project.cfg.deps[name]))
    for name in sortedKeys(project.cfg.sources):
      lines.add("source=" & project.path & "|" &
        sourceLine(name, project.cfg.sources[name]))
    for name in sortedKeys(project.cfg.features):
      var enables = project.cfg.features[name].enables
      enables.sort()
      lines.add("feature=" & project.path & "|" & name & "|" &
        enables.join(","))
  hashStr(lines.join("\n"))

proc readStringSeq(table: TomlValueRef; key: string): seq[string] =
  if table.hasKey(key) and table[key].kind == TomlValueKind.Array:
    for item in table[key].getElems():
      result.add(item.getStr())

proc readBool(table: TomlValueRef; key: string): bool =
  if table.hasKey(key) and table[key].kind == TomlValueKind.Bool:
    result = table[key].getBool()

proc readInt(table: TomlValueRef; key: string): int =
  if table.hasKey(key):
    result = table[key].getInt()

proc readStr(table: TomlValueRef; key: string): string =
  if table.hasKey(key):
    result = table[key].getStr()

proc parseEdge(value: string): DependencyEdge =
  let parts = value.split("|")
  if parts.len > 0: result.name = parts[0]
  if parts.len > 1: result.requirement = parts[1]
  if parts.len > 2: result.package = parts[2]
  if parts.len > 3: result.optional = parts[3] == "true"

proc edgeString(edge: DependencyEdge): string =
  edge.name & "|" & edge.requirement & "|" & edge.package & "|" & $edge.optional

proc parseRootReq(table: TomlValueRef): DependencyReq =
  result.name = readStr(table, "name")
  result.requirement = readStr(table, "requirement")
  result.source = readStr(table, "source")
  result.registry = readStr(table, "registry")
  result.url = readStr(table, "url")
  result.path = readStr(table, "path")
  result.tag = readStr(table, "tag")
  result.branch = readStr(table, "branch")
  result.rev = readStr(table, "rev")
  result.optional = readBool(table, "optional")
  result.enabledBy = readStringSeq(table, "enabledBy")
  result.workspaceMember = readStr(table, "workspaceMember")

proc parsePackage(table: TomlValueRef): ResolvedPackage =
  result.id.name = readStr(table, "name")
  result.id.version = readStr(table, "version")
  result.id.source = readStr(table, "source")
  result.revision = readStr(table, "revision")
  result.checksum = readStr(table, "checksum")
  result.path = readStr(table, "path")
  result.direct = readBool(table, "direct")
  result.optional = readBool(table, "optional")
  result.enabledBy = readStringSeq(table, "enabledBy")
  result.materialized = readBool(table, "materialized")
  result.lockedAt = readInt(table, "lockedAt")
  for item in readStringSeq(table, "dependencies"):
    result.dependencies.add(parseEdge(item))

proc parseLockFile*(path: string): LockFile =
  ## Parse a Bau lockfile from disk.
  ##
  ## Missing files return an empty lockfile; unsupported versions raise.
  result = initLockFile()
  if not fileExists(path):
    return
  let root = parsetoml.parseFile(path)
  if root.hasKey("version"):
    result.version = root["version"].getInt()
  if result.version != LockFileVersion:
    raise newException(ValueError, LockFileName & " has unsupported version " &
      $result.version & "; run bau deps lock to regenerate it")
  result.resolver = readStr(root, "resolver")
  if result.resolver.len == 0:
    result.resolver = DefaultResolver
  result.requirementsHash = readStr(root, "requirementsHash")
  result.workspaceMembers = readStringSeq(root, "workspaceMembers")
  if root.hasKey("rootDependency") and
      root["rootDependency"].kind == TomlValueKind.Array:
    for item in root["rootDependency"].getElems():
      if item.kind == TomlValueKind.Table:
        result.rootDependencies.add(parseRootReq(item))
  if root.hasKey("package") and root["package"].kind == TomlValueKind.Array:
    for item in root["package"].getElems():
      if item.kind == TomlValueKind.Table:
        let pkg = parsePackage(item)
        result.packages[pkg.toString()] = pkg

proc writeStringArray(content: var string; key: string; values: openArray[string]) =
  content.add(key & " = [")
  for i, value in values:
    if i > 0:
      content.add(", ")
    content.add(toTomlString(value))
  content.add("]\n")

proc writeRootReq(content: var string; req: DependencyReq) =
  content.add("[[rootDependency]]\n")
  content.add("name = " & toTomlString(req.name) & "\n")
  if req.requirement.len > 0:
    content.add("requirement = " & toTomlString(req.requirement) & "\n")
  if req.source.len > 0:
    content.add("source = " & toTomlString(req.source) & "\n")
  if req.registry.len > 0:
    content.add("registry = " & toTomlString(req.registry) & "\n")
  if req.url.len > 0:
    content.add("url = " & toTomlString(req.url) & "\n")
  if req.path.len > 0:
    content.add("path = " & toTomlString(req.path) & "\n")
  if req.tag.len > 0:
    content.add("tag = " & toTomlString(req.tag) & "\n")
  if req.branch.len > 0:
    content.add("branch = " & toTomlString(req.branch) & "\n")
  if req.rev.len > 0:
    content.add("rev = " & toTomlString(req.rev) & "\n")
  if req.optional:
    content.add("optional = true\n")
  content.writeStringArray("enabledBy", req.enabledBy)
  if req.workspaceMember.len > 0:
    content.add("workspaceMember = " & toTomlString(req.workspaceMember) & "\n")
  content.add("\n")

proc writePackage(content: var string; pkg: ResolvedPackage) =
  content.add("[[package]]\n")
  content.add("name = " & toTomlString(pkg.id.name) & "\n")
  content.add("version = " & toTomlString(pkg.id.version) & "\n")
  content.add("source = " & toTomlString(pkg.id.source) & "\n")
  if pkg.revision.len > 0:
    content.add("revision = " & toTomlString(pkg.revision) & "\n")
  if pkg.checksum.len > 0:
    content.add("checksum = " & toTomlString(pkg.checksum) & "\n")
  if pkg.path.len > 0:
    content.add("path = " & toTomlString(pkg.path) & "\n")
  if pkg.direct:
    content.add("direct = true\n")
  if pkg.optional:
    content.add("optional = true\n")
  if pkg.materialized:
    content.add("materialized = true\n")
  if pkg.lockedAt > 0:
    content.add("lockedAt = " & $pkg.lockedAt & "\n")
  content.writeStringArray("enabledBy", pkg.enabledBy)
  var deps: seq[string]
  for edge in pkg.dependencies:
    deps.add(edgeString(edge))
  deps.sort()
  content.writeStringArray("dependencies", deps)
  content.add("\n")

proc writeLockFile*(lock: LockFile; path: string) =
  ## Write a lockfile in Bau's deterministic TOML format.
  var content = "# bau.lock - @generated by bau, do not edit\n"
  content.add("version = " & $LockFileVersion & "\n")
  content.add("resolver = " & toTomlString(lock.resolver) & "\n")
  content.add("requirementsHash = " & toTomlString(lock.requirementsHash) & "\n")
  content.writeStringArray("workspaceMembers", lock.workspaceMembers)
  content.add("\n")
  for req in lock.rootDependencies:
    content.writeRootReq(req)
  for key in sortedOrderedKeys(lock.packages):
    content.writePackage(lock.packages[key])
  saveFile(path, content)

proc atlasConfigExists(projectDir: string): bool =
  fileExists(projectDir / "atlas" / "atlas.config") or
    fileExists(projectDir / "deps" / "atlas.config")

proc captureAtlasBridge(projectDir: string): Table[string, AtlasBridgeEntry] =
  if not atlasConfigExists(projectDir):
    return
  let bridgePath = projectDir / BuildDirName / ".bau" / "atlas-bridge.lock"
  try:
    createDir(parentDir(bridgePath))
    let atlasCmd = detectAtlas()
    let (exitCode, output) = runCmd(atlasCmd, ["--project=" & projectDir,
      "--deps=" & projectDir / "deps", "pin", bridgePath], projectDir)
    if exitCode != 0 or not fileExists(bridgePath):
      warn("atlas bridge pin failed; building lock graph from materialized deps: " &
        output.strip())
      return
    let node = parseJson(readFileChecked(bridgePath))
    if not node.hasKey("items"):
      return
    for name, item in node["items"].pairs:
      result[name] = AtlasBridgeEntry(
        dir: item{"dir"}.getStr(""),
        url: item{"url"}.getStr(""),
        commit: item{"commit"}.getStr(""),
        version: item{"version"}.getStr(""))
  except CatchableError as e:
    warn("atlas bridge unavailable; building lock graph from materialized deps: " &
      e.msg)

proc bridgePath(projectDir: string; entry: AtlasBridgeEntry): string =
  if entry.dir.len == 0:
    return ""
  var path = entry.dir
  if path.startsWith("$deps"):
    path.removePrefix("$deps")
    result = projectDir / "deps" / path.strip(chars = {'/', '\\'})
  elif path.startsWith("$project"):
    path.removePrefix("$project")
    result = projectDir / path.strip(chars = {'/', '\\'})
  elif path.isAbsolute:
    result = path
  else:
    result = projectDir / path

proc packageFromMaterial(name: string; dep: DepInfo; project: LockProject;
    workspaceRoot: string; bridge: AtlasBridgeEntry; direct: bool;
    optional: bool; enabledBy: seq[string]; nowUnix: int): ResolvedPackage =
  let depPath = if bridge.dir.len > 0 and materialExists(bridgePath(
                  project.projectDir, bridge)):
                  bridgePath(project.projectDir, bridge)
                else:
                  dependencyMaterialPath(project.projectDir, name, dep,
                    project.cfg)
  let exists = materialExists(depPath)
  let rev = if bridge.commit.len > 0: bridge.commit
            elif dep.rev.isSome: dep.rev.get()
            else: gitRevision(depPath)
  let url = if bridge.url.len > 0: bridge.url else: dep.url.get(gitOrigin(depPath))
  var sourceDep = dep
  if url.len > 0 and sourceDep.url.isNone:
    sourceDep.url = some(url)
  let version = if bridge.version.len > 0: bridge.version
                elif exists: readNimbleVersion(depPath, name)
                else: dep.version.get("")
  result.id = PackageId(
    name: if exists: readNimblePackageName(depPath, name) else: name,
    version: version,
    source: depSourceUri(sourceDep, project, workspaceRoot, name,
      depPath, rev))
  result.revision = rev
  result.direct = direct
  result.optional = optional
  result.enabledBy = enabledBy
  result.materialized = exists
  if exists:
    result.path = relTo(workspaceRoot, depPath)
    result.checksum = checksumPath(depPath)
    result.dependencies = readNimbleDependencies(depPath, name)
    result.lockedAt = nowUnix

proc packageFromDepsDir(depPath, projectDir, workspaceRoot: string;
    bridge: Table[string, AtlasBridgeEntry]; nowUnix: int;
    sourceUri = ""): ResolvedPackage =
  let fallback = depPath.extractFilename
  let name = readNimblePackageName(depPath, fallback)
  let bridgeEntry = bridge.getOrDefault(name)
  let rev = if bridgeEntry.commit.len > 0: bridgeEntry.commit
            else: gitRevision(depPath)
  let url = if bridgeEntry.url.len > 0: bridgeEntry.url else: gitOrigin(depPath)
  let source = if url.len > 0:
                 "git+" & url & (if rev.len > 0: "#" & rev else: "")
               elif sourceUri.len > 0:
                 sourceUri
               else:
                 "registry+nimble://default"
  result.id = PackageId(
    name: name,
    version: if bridgeEntry.version.len > 0: bridgeEntry.version
             else: readNimbleVersion(depPath, name),
    source: source)
  result.revision = rev
  result.checksum = checksumPath(depPath)
  result.path = relTo(workspaceRoot, depPath)
  result.dependencies = readNimbleDependencies(depPath, name)
  result.materialized = true
  result.lockedAt = nowUnix

proc materialRoots(project: LockProject): seq[tuple[path: string;
    sourceUri: string]] =
  result.add((path: project.projectDir / "deps", sourceUri: ""))
  var seen = initHashSet[string]()
  seen.incl(normalizedPath(absolutePath(project.projectDir / "deps")))
  for name in sortedKeys(project.cfg.sources):
    let provider = resolvedSourceProvider(project.cfg.sources, name)
    let root = sourceMaterialRoot(provider, project.projectDir)
    if root.len > 0:
      let clean = normalizedPath(absolutePath(root))
      if clean notin seen:
        seen.incl(clean)
        result.add((path: root, sourceUri: provider.uri))

proc preserveLockedAt(existing: LockFile; pkg: var ResolvedPackage;
    nowUnix: int) =
  let key = pkg.toString()
  if existing.packages.hasKey(key):
    let old = existing.packages[key]
    if old.revision == pkg.revision and old.checksum == pkg.checksum and
        old.lockedAt > 0:
      pkg.lockedAt = old.lockedAt
      return
  if pkg.materialized and pkg.lockedAt == 0:
    pkg.lockedAt = nowUnix

proc addPackage(graph: var ResolveGraph; existing: LockFile;
    pkg: ResolvedPackage; nowUnix: int) =
  var item = pkg
  existing.preserveLockedAt(item, nowUnix)
  let key = item.toString()
  if graph.packages.hasKey(key):
    var old = graph.packages[key]
    old.direct = old.direct or item.direct
    old.optional = old.optional and item.optional
    for feature in item.enabledBy:
      old.enabledBy.addUnique(feature)
    if old.path.len == 0:
      old.path = item.path
    if old.checksum.len == 0:
      old.checksum = item.checksum
    if old.revision.len == 0:
      old.revision = item.revision
    if item.materialized:
      old.materialized = true
    graph.packages[key] = old
  else:
    graph.packages[key] = item

proc resolveDependencyEdges(graph: var ResolveGraph) =
  var byName = initTable[string, string]()
  for key, pkg in graph.packages.pairs:
    if not byName.hasKey(pkg.id.name):
      byName[pkg.id.name] = key
  for key in graph.packages.keys.toSeq:
    var pkg = graph.packages[key]
    for edge in pkg.dependencies.mitems:
      if edge.package.len == 0 and byName.hasKey(edge.name):
        edge.package = byName[edge.name]
    graph.packages[key] = pkg

proc buildResolveGraph*(projects: openArray[LockProject];
    workspaceRoot: string): ResolveGraph =
  ## Build a dependency graph from configured projects and materialized packages.
  result = initResolveGraph()
  result.requirementsHash = requirementsHash(projects, workspaceRoot)
  let nowUnix = int(getTime().toUnix)
  var existing = initLockFile()
  try:
    if fileExists(workspaceRoot / LockFileName):
      existing = parseLockFile(workspaceRoot / LockFileName)
  except CatchableError:
    discard

  var bridgeByProject = initTable[string, Table[string, AtlasBridgeEntry]]()
  for project in projects:
    result.workspaceMembers.addUnique(project.path)
    bridgeByProject[project.projectDir] = captureAtlasBridge(project.projectDir)

  for project in projects:
    let bridge = bridgeByProject[project.projectDir]
    for name in sortedKeys(project.cfg.deps):
      let dep = project.cfg.deps[name]
      let req = depReq(name, dep, project, workspaceRoot)
      result.rootDependencies.add(req)
      let pkg = packageFromMaterial(name, dep, project, workspaceRoot,
        bridge.getOrDefault(name), direct = true, optional = dep.optional,
        enabledBy = req.enabledBy, nowUnix = nowUnix)
      result.addPackage(existing, pkg, nowUnix)

    for root in project.materialRoots():
      if dirExists(root.path):
        for kind, path in walkDir(root.path):
          if kind == pcDir:
            let pkg = packageFromDepsDir(path, project.projectDir,
              workspaceRoot,
              bridge, nowUnix, root.sourceUri)
            result.addPackage(existing, pkg, nowUnix)

  result.rootDependencies.sort(proc(a, b: DependencyReq): int =
    cmp(reqLine(a), reqLine(b)))
  result.workspaceMembers.sort()
  result.resolveDependencyEdges()

proc toLockFile*(graph: ResolveGraph): LockFile =
  ## Convert an in-memory resolve graph to lockfile content.
  result = initLockFile()
  result.resolver = graph.resolver
  result.requirementsHash = graph.requirementsHash
  result.workspaceMembers = graph.workspaceMembers
  result.rootDependencies = graph.rootDependencies
  result.packages = graph.packages

proc generateLockFile*(projects: openArray[LockProject];
    workspaceRoot: string): LockFile =
  ## Generate a lockfile for a workspace project set.
  buildResolveGraph(projects, workspaceRoot).toLockFile()

proc generateLockFile*(cfg: BauConfig; projectDir: string = ""): LockFile =
  ## Generate a lockfile for a single project configuration.
  let root = if projectDir.len > 0: projectDir else: getCurrentDir()
  let project = LockProject(path: ".", projectDir: root, cfg: cfg)
  generateLockFile(@[project], root)

proc packageMaterialPath*(workspaceRoot: string; pkg: ResolvedPackage): string =
  ## Return the absolute materialized package path for a resolved package.
  if pkg.path.len > 0:
    result = workspaceRoot / pkg.path

proc directPackageNames(lock: LockFile): HashSet[string] =
  result = initHashSet[string]()
  for pkg in lock.packages.values:
    if pkg.direct:
      result.incl(pkg.id.name)

proc addDiagnostic(report: var LockValidationReport; kind: LockDiagnosticKind;
    message: string; packageName = ""; path = "") =
  report.ok = false
  report.messages.add(message)
  report.diagnostics.add(LockDiagnostic(kind: kind, packageName: packageName,
    path: path, message: message))

proc validateLockFile*(projects: openArray[LockProject]; workspaceRoot,
    lockPath: string): LockValidationReport =
  ## Validate a lockfile against workspace projects and materialized packages.
  result.ok = true
  if not fileExists(lockPath):
    result.addDiagnostic(ldkMissingLock, "missing " & LockFileName,
      path = lockPath)
    return
  var lock: LockFile
  try:
    lock = parseLockFile(lockPath)
  except CatchableError as e:
    result.addDiagnostic(ldkInvalidLock, e.msg, path = lockPath)
    return

  let expectedHash = requirementsHash(projects, workspaceRoot)
  if lock.requirementsHash != expectedHash:
    result.addDiagnostic(ldkStaleRequirements, LockFileName &
      " is out of date", path = lockPath)

  let directNames = lock.directPackageNames()
  for project in projects:
    for name, dep in project.cfg.deps.pairs:
      if not dep.optional and name notin directNames:
        result.addDiagnostic(ldkMissingDependency,
          "lock is missing dependency: " & name, packageName = name,
          path = project.projectDir)

  for key, pkg in lock.packages.pairs:
    if pkg.materialized:
      let path = packageMaterialPath(workspaceRoot, pkg)
      if not materialExists(path):
        result.addDiagnostic(ldkMissingMaterial,
          "dependency material unavailable: " & pkg.id.name,
          packageName = pkg.id.name, path = path)
      elif pkg.checksum.len == 0 or checksumPath(path) != pkg.checksum:
        result.addDiagnostic(ldkChecksumMismatch,
          "checksum mismatch for " & pkg.id.name,
          packageName = pkg.id.name, path = path)
      elif pkg.revision.len > 0:
        let rev = gitRevision(path)
        if rev.len > 0 and rev != pkg.revision:
          result.addDiagnostic(ldkRevisionMismatch,
            "git revision mismatch for " & pkg.id.name,
            packageName = pkg.id.name, path = path)
    elif pkg.direct and not pkg.optional:
      result.addDiagnostic(ldkUnmaterialized,
        "dependency is not materialized: " & pkg.id.name,
        packageName = pkg.id.name)

proc validateLockFile*(cfg: BauConfig; projectDir, lockPath: string):
    LockValidationReport =
  ## Validate a lockfile against a single project configuration.
  let root = if projectDir.len > 0: projectDir else: getCurrentDir()
  let project = LockProject(path: ".", projectDir: root, cfg: cfg)
  validateLockFile(@[project], root, lockPath)

proc lockIsValid*(projects: openArray[LockProject]; workspaceRoot,
    lockPath: string): bool =
  ## Return true when a workspace lockfile validates successfully.
  validateLockFile(projects, workspaceRoot, lockPath).ok

proc lockIsValid*(cfg: BauConfig; lockPath: string;
    projectDir: string = ""): bool =
  ## Return true when a single-project lockfile validates successfully.
  validateLockFile(cfg, projectDir, lockPath).ok

proc unresolvedLockEntries*(cfg: BauConfig; lock: LockFile;
    projectDir: string): seq[string] =
  ## Return non-optional dependencies that are missing resolved material.
  discard projectDir
  let directNames = lock.directPackageNames()
  for name, dep in cfg.deps.pairs:
    if dep.optional:
      continue
    if name notin directNames:
      result.add(name)
      continue
    var resolved = false
    for pkg in lock.packages.values:
      if pkg.direct and pkg.id.name == name and pkg.materialized and
          pkg.checksum.len > 0:
        resolved = true
        break
    if not resolved:
      result.add(name)
  result.sort()
