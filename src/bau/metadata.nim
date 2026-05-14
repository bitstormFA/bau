## Builds structured metadata, graph, and dependency query output.

import std/[algorithm, json, options, os, sets, strutils, tables]
import bau/[config, fingerprint, lock, util]

proc sortedKeys[T](table: Table[string, T]): seq[string] =
  for key in table.keys:
    result.add(key)
  result.sort()

proc sortedOrderedKeys[T](table: OrderedTable[string, T]): seq[string] =
  for key in table.keys:
    result.add(key)
  result.sort()

proc depToJson(dep: DepInfo): JsonNode =
  result = newJObject()
  if dep.url.isSome:
    result["git"] = %dep.url.get()
  if dep.tag.isSome:
    result["tag"] = %dep.tag.get()
  if dep.branch.isSome:
    result["branch"] = %dep.branch.get()
  if dep.rev.isSome:
    result["rev"] = %dep.rev.get()
  if dep.path.isSome:
    result["path"] = %dep.path.get()
  if dep.version.isSome:
    result["version"] = %dep.version.get()
  if dep.registry.isSome:
    result["registry"] = %dep.registry.get()
  result["optional"] = %dep.optional

proc sourceToJson(source: SourceInfo): JsonNode =
  result = newJObject()
  if source.registry.len > 0:
    result["registry"] = %source.registry
  if source.directory.len > 0:
    result["directory"] = %source.directory
  if source.localRegistry.len > 0:
    result["localRegistry"] = %source.localRegistry
  if source.git.len > 0:
    result["git"] = %source.git
  if source.replaceWith.len > 0:
    result["replaceWith"] = %source.replaceWith

proc lockPackageToJson(pkg: ResolvedPackage): JsonNode =
  var deps = newJArray()
  for edge in pkg.dependencies:
    deps.add(%*{
      "name": edge.name,
      "requirement": edge.requirement,
      "package": edge.package,
      "optional": edge.optional
    })
  %*{
    "name": pkg.id.name,
    "version": pkg.id.version,
    "source": pkg.id.source,
    "revision": pkg.revision,
    "checksum": pkg.checksum,
    "path": pkg.path,
    "direct": pkg.direct,
    "optional": pkg.optional,
    "enabledBy": pkg.enabledBy,
    "materialized": pkg.materialized,
    "lockedAt": pkg.lockedAt,
    "dependencies": deps
  }

proc configuredDependencySource(dep: DepInfo): string =
  if dep.path.isSome:
    result = "path+" & dep.path.get()
  elif dep.url.isSome:
    result = "git+" & dep.url.get()
  elif dep.registry.isSome:
    let registry = dep.registry.get()
    if registry.contains("://"):
      result = "registry+" & registry
    else:
      result = "registry+nimble://" & registry
  else:
    result = "registry+nimble://default"

proc findLockedPackageKey(lockFile: LockFile; name: string): string =
  for key in sortedOrderedKeys(lockFile.packages):
    let pkg = lockFile.packages[key]
    if pkg.id.name == name and pkg.direct:
      return key
  for key in sortedOrderedKeys(lockFile.packages):
    if lockFile.packages[key].id.name == name:
      return key

proc packageTreeNode(lockFile: LockFile; key: string;
    seen: HashSet[string]): JsonNode

proc edgeTreeNode(lockFile: LockFile; edge: DependencyEdge;
    seen: HashSet[string]): JsonNode =
  result = %*{
    "name": edge.name,
    "requirement": edge.requirement,
    "package": edge.package,
    "optional": edge.optional,
    "resolved": false
  }
  if edge.package.len > 0 and lockFile.packages.hasKey(edge.package):
    result["resolved"] = %true
    result["package"] = packageTreeNode(lockFile, edge.package, seen)

proc packageTreeNode(lockFile: LockFile; key: string;
    seen: HashSet[string]): JsonNode =
  if not lockFile.packages.hasKey(key):
    return %*{"id": key, "missing": true, "dependencies": []}
  if seen.contains(key):
    return %*{"id": key, "cycle": true, "dependencies": []}

  var nextSeen = seen
  nextSeen.incl(key)
  let pkg = lockFile.packages[key]
  var deps = newJArray()
  for edge in pkg.dependencies:
    deps.add(edgeTreeNode(lockFile, edge, nextSeen))

  result = lockPackageToJson(pkg)
  result["id"] = %key
  result["dependencies"] = deps

proc directDependencyNode(name: string; dep: DepInfo): JsonNode =
  %*{
    "name": name,
    "requirement": dep.version.get(""),
    "source": configuredDependencySource(dep),
    "optional": dep.optional,
    "locked": newJNull()
  }

proc dependencyTreeJson*(cfg: BauConfig; projectDir: string): JsonNode =
  ## Build JSON describing configured and locked dependency trees.
  result = %*{
    "package": cfg.package.name,
    "projectDir": projectDir,
    "lockPresent": fileExists(projectDir / LockFileName),
    "dependencies": []
  }

  var lockLoaded = false
  var lockFile = initLockFile()
  if result["lockPresent"].getBool():
    try:
      lockFile = parseLockFile(projectDir / LockFileName)
      lockLoaded = true
      result["lock"] = %*{
        "version": lockFile.version,
        "resolver": lockFile.resolver,
        "requirementsHash": lockFile.requirementsHash,
        "workspaceMembers": lockFile.workspaceMembers
      }
    except CatchableError as e:
      result["lock"] = %*{"error": e.msg}

  for name in sortedKeys(cfg.deps):
    var node = directDependencyNode(name, cfg.deps[name])
    if lockLoaded:
      let key = findLockedPackageKey(lockFile, name)
      if key.len > 0:
        node["locked"] = packageTreeNode(lockFile, key, initHashSet[string]())
    result["dependencies"].add(node)

  if lockLoaded:
    var transitive = newJArray()
    for key in sortedOrderedKeys(lockFile.packages):
      if not lockFile.packages[key].direct:
        transitive.add(packageTreeNode(lockFile, key, initHashSet[string]()))
    result["transitivePackages"] = transitive

proc diagnosticToJson(diag: LockDiagnostic): JsonNode =
  %*{
    "kind": $diag.kind,
    "package": diag.packageName,
    "path": diag.path,
    "message": diag.message
  }

proc dependencyStatusJson*(cfg: BauConfig; projectDir: string): JsonNode =
  ## Build JSON describing dependency lock health and materialization status.
  let lockPath = projectDir / LockFileName
  result = %*{
    "package": cfg.package.name,
    "projectDir": projectDir,
    "lockPresent": fileExists(lockPath),
    "lockOk": false,
    "diagnostics": [],
    "dependencies": []
  }

  var lockLoaded = false
  var lockInvalid = false
  var lockFile = initLockFile()
  var diagnostics: seq[LockDiagnostic]
  var staleRequirements = false

  if fileExists(lockPath):
    try:
      let report = validateLockFile(cfg, projectDir, lockPath)
      result["lockOk"] = %report.ok
      diagnostics = report.diagnostics
      for diag in diagnostics:
        if diag.kind == ldkStaleRequirements:
          staleRequirements = true
        result["diagnostics"].add(diagnosticToJson(diag))
      lockFile = parseLockFile(lockPath)
      lockLoaded = true
      result["lock"] = %*{
        "version": lockFile.version,
        "resolver": lockFile.resolver,
        "requirementsHash": lockFile.requirementsHash,
        "workspaceMembers": lockFile.workspaceMembers
      }
    except CatchableError as e:
      lockInvalid = true
      result["diagnostics"].add(%*{
        "kind": "invalid-lock",
        "package": "",
        "path": lockPath,
        "message": e.msg
      })
  else:
    result["diagnostics"].add(%*{
      "kind": "missing-lock",
      "package": "",
      "path": lockPath,
      "message": LockFileName & " is missing"
    })

  for name in sortedKeys(cfg.deps):
    let dep = cfg.deps[name]
    var node = %*{
      "name": name,
      "requirement": dep.version.get(""),
      "source": configuredDependencySource(dep),
      "optional": dep.optional,
      "status": "ok",
      "lockedVersion": newJNull(),
      "lockedSource": newJNull(),
      "materialized": false,
      "diagnostics": []
    }

    if not fileExists(lockPath):
      node["status"] = %"unlocked"
    elif lockInvalid:
      node["status"] = %"invalid-lock"
    elif lockLoaded:
      let key = findLockedPackageKey(lockFile, name)
      if key.len == 0:
        node["status"] = %"missing"
      else:
        let pkg = lockFile.packages[key]
        node["lockedVersion"] = %pkg.id.version
        node["lockedSource"] = %pkg.id.source
        node["materialized"] = %pkg.materialized

    var packageHasDiagnostic = false
    for diag in diagnostics:
      if diag.packageName == name:
        packageHasDiagnostic = true
        node["diagnostics"].add(diagnosticToJson(diag))
        node["status"] = %($diag.kind)
    if staleRequirements and not packageHasDiagnostic and
        node["status"].getStr() == "ok":
      node["status"] = %"stale-lock"
    result["dependencies"].add(node)

proc appendDependencyEdgesText(content: var string; pkg: JsonNode; indent: int)

proc appendDependencyEdgeText(content: var string; edge: JsonNode; indent: int) =
  let prefix = repeat(" ", indent)
  var line = prefix & "- " & edge["name"].getStr()
  if edge["requirement"].getStr().len > 0:
    line.add(" " & edge["requirement"].getStr())
  if edge{"resolved"}.getBool(false) and edge["package"].kind == JObject:
    let pkg = edge["package"]
    if pkg{"version"}.getStr().len > 0:
      line.add(" -> " & pkg["version"].getStr())
    if pkg{"source"}.getStr().len > 0:
      line.add(" (" & pkg["source"].getStr() & ")")
    if not pkg{"materialized"}.getBool(false):
      line.add(" [unmaterialized]")
    content.add(line & "\n")
    appendDependencyEdgesText(content, pkg, indent + 2)
  else:
    line.add(" [unresolved]")
    content.add(line & "\n")

proc appendDependencyEdgesText(content: var string; pkg: JsonNode; indent: int) =
  if pkg.hasKey("dependencies") and pkg["dependencies"].kind == JArray:
    for edge in pkg["dependencies"].getElems():
      appendDependencyEdgeText(content, edge, indent)

proc dependencyTreeText*(cfg: BauConfig; projectDir: string): string =
  ## Format the dependency tree as human-readable text.
  let tree = dependencyTreeJson(cfg, projectDir)
  result = "dependencies for " & cfg.package.name & "\n"
  if not tree["lockPresent"].getBool():
    result.add("lock: missing; showing configured direct dependencies\n")
  elif tree.hasKey("lock") and tree["lock"].hasKey("error"):
    result.add("lock: " & tree["lock"]["error"].getStr() & "\n")
  else:
    result.add("lock: " & tree["lock"]["resolver"].getStr() & "\n")

  if tree["dependencies"].len == 0:
    result.add("  none\n")
    return

  for dep in tree["dependencies"].getElems():
    var line = "  - " & dep["name"].getStr()
    if dep["requirement"].getStr().len > 0:
      line.add(" " & dep["requirement"].getStr())
    if dep{"optional"}.getBool(false):
      line.add(" [optional]")
    if dep["locked"].kind == JObject:
      let locked = dep["locked"]
      if locked{"version"}.getStr().len > 0:
        line.add(" -> " & locked["version"].getStr())
      if locked{"source"}.getStr().len > 0:
        line.add(" (" & locked["source"].getStr() & ")")
      if not locked{"materialized"}.getBool(false):
        line.add(" [unmaterialized]")
      result.add(line & "\n")
      appendDependencyEdgesText(result, locked, 4)
    else:
      line.add(" [unlocked]")
      result.add(line & "\n")

proc dependencyStatusText*(cfg: BauConfig; projectDir: string): string =
  ## Format dependency lock health and materialization status as text.
  let status = dependencyStatusJson(cfg, projectDir)
  result = "dependency status for " & cfg.package.name & "\n"
  if status["lockPresent"].getBool():
    result.add("lock: " & (if status["lockOk"].getBool(): "OK" else: "issues") &
      "\n")
  else:
    result.add("lock: missing\n")

  if status["diagnostics"].len > 0:
    result.add("diagnostics:\n")
    for diag in status["diagnostics"].getElems():
      var line = "  - " & diag["kind"].getStr()
      if diag["package"].getStr().len > 0:
        line.add(" " & diag["package"].getStr())
      if diag["message"].getStr().len > 0:
        line.add(": " & diag["message"].getStr())
      result.add(line & "\n")

  if status["dependencies"].len == 0:
    result.add("dependencies: none\n")
    return

  result.add("dependencies:\n")
  for dep in status["dependencies"].getElems():
    var line = "  - " & dep["name"].getStr() & ": " &
      dep["status"].getStr()
    if dep["requirement"].getStr().len > 0:
      line.add(" requested " & dep["requirement"].getStr())
    if dep["lockedVersion"].kind != JNull:
      line.add(", locked " & dep["lockedVersion"].getStr())
    if dep{"materialized"}.getBool(false):
      line.add(", materialized")
    result.add(line & "\n")

proc profileToJson(profile: ProfileInfo): JsonNode =
  result = %*{
    "flags": profile.flags,
    "gc": profile.gc,
    "extends": profile.extends,
    "backend": profile.backend
  }
  var define = newJObject()
  for key, val in profile.define.pairs:
    define[key] = %val
  result["define"] = define

proc targetToJson(target: TargetInfo): JsonNode =
  %*{
    "name": target.name,
    "kind": $target.kind,
    "main": target.main,
    "output": target.output,
    "source": target.source,
    "paths": target.paths,
    "profile": target.profile,
    "requiredFeatures": target.requiredFeatures,
    "tags": target.tags
  }

proc taskToJson(task: TaskInfo): JsonNode =
  %*{
    "name": task.name,
    "cmd": task.cmd,
    "command": task.command,
    "description": task.description,
    "deps": task.deps,
    "inputs": task.inputs,
    "outputs": task.outputs,
    "shell": task.shell,
    "profile": task.profile,
    "envInputs": task.envInputs,
    "cache": task.cache,
    "acceptArgs": task.acceptArgs,
    "requiredFeatures": task.requiredFeatures,
    "tags": task.tags
  }

proc docsToJson(docs: DocsInfo): JsonNode =
  %*{
    "outDir": docs.outDir,
    "docRoot": docs.docRoot,
    "entrypoints": docs.entrypoints,
    "include": docs.includeFiles,
    "exclude": docs.excludeFiles,
    "flags": docs.flags,
    "project": docs.project,
    "index": docs.index,
    "runExamples": docs.runExamples,
    "includePrivate": docs.includePrivate,
    "sourceUrl": docs.sourceUrl
  }

proc testToJson(test: TestInfo): JsonNode =
  %*{
    "runner": test.runner,
    "profiles": test.profiles,
    "defaultProfile": test.defaultProfile,
    "fullProfiles": test.fullProfiles,
    "recursive": test.recursive,
    "exclude": test.exclude,
    "showOutput": test.showOutput
  }

proc configMetadataJson*(cfg: BauConfig; projectDir: string;
    formatVersion: int = 1): JsonNode =
  ## Build structured metadata for the effective Bau configuration.
  result = newJObject()
  result["formatVersion"] = %formatVersion
  result["projectDir"] = %projectDir
  result["package"] = %*{
    "name": cfg.package.name,
    "version": cfg.package.version,
    "description": cfg.package.description,
    "authors": cfg.package.authors,
    "license": cfg.package.license,
    "edition": cfg.package.edition,
    "repository": cfg.package.repository,
    "homepage": cfg.package.homepage,
    "include": cfg.package.includeFiles,
    "exclude": cfg.package.excludeFiles
  }
  result["build"] = %*{
    "name": cfg.build.name,
    "kind": $cfg.build.kind,
    "source": cfg.build.source,
    "main": cfg.build.main,
    "output": cfg.build.output,
    "nim": cfg.build.nim,
    "backend": cfg.build.backend,
    "includeDefault": cfg.build.includeDefault
  }
  result["toolchain"] = %*{
    "nim": cfg.toolchain.nim,
    "atlas": cfg.toolchain.atlas,
    "detectedNim": NimVersion
  }
  result["governance"] = %*{
    "blocked": cfg.governance.blocked,
    "trusted": cfg.governance.trusted,
    "minimumReleaseAgeHours": cfg.governance.minimumReleaseAgeHours
  }
  result["cache"] = %*{
    "dir": cfg.cache.dir,
    "remote": cfg.cache.remote,
    "read": cfg.cache.read,
    "write": cfg.cache.write
  }
  result["docs"] = docsToJson(cfg.docs)
  result["test"] = testToJson(cfg.test)

  var profiles = newJObject()
  for name, profile in cfg.profiles.pairs:
    profiles[name] = profileToJson(profile)
  result["profiles"] = profiles

  var features = newJObject()
  for name, feature in cfg.features.pairs:
    features[name] = %*{"enables": feature.enables}
  result["features"] = features

  var aliases = newJObject()
  for name, command in cfg.aliases.pairs:
    aliases[name] = %command
  result["aliases"] = aliases

  var catalogs = newJObject()
  for name, catalog in cfg.catalogs.pairs:
    var catalogNode = newJObject()
    for depName, version in catalog.pairs:
      catalogNode[depName] = %version
    catalogs[name] = catalogNode
  result["catalogs"] = catalogs

  var targets = newJArray()
  for target in cfg.targets:
    targets.add(targetToJson(target))
  result["targets"] = targets

  var deps = newJObject()
  for name, dep in cfg.deps.pairs:
    deps[name] = depToJson(dep)
  result["dependencies"] = deps

  var sources = newJObject()
  for name, source in cfg.sources.pairs:
    sources[name] = sourceToJson(source)
  result["sources"] = sources

  var patches = newJObject()
  for name, dep in cfg.patches.pairs:
    patches[name] = depToJson(dep)
  result["patches"] = patches

  var tasks = newJArray()
  var buildScripts = newJArray()
  for script in cfg.buildScripts:
    buildScripts.add(taskToJson(script))
  result["buildScripts"] = buildScripts

  for task in cfg.tasks:
    tasks.add(taskToJson(task))
  result["tasks"] = tasks

  if fileExists(projectDir / LockFileName):
    try:
      let lockFile = parseLockFile(projectDir / LockFileName)
      var locked = newJArray()
      for key in sortedOrderedKeys(lockFile.packages):
        locked.add(lockPackageToJson(lockFile.packages[key]))
      result["resolvedDependencies"] = locked
      result["lock"] = %*{
        "version": lockFile.version,
        "resolver": lockFile.resolver,
        "requirementsHash": lockFile.requirementsHash,
        "workspaceMembers": lockFile.workspaceMembers
      }
    except CatchableError as e:
      result["lock"] = %*{"error": e.msg}

proc addResolvedGraph(graph: var JsonNode; projectDir: string) =
  if not fileExists(projectDir / LockFileName):
    return
  try:
    let lockFile = parseLockFile(projectDir / LockFileName)
    var seen = initTable[string, bool]()
    for key in sortedOrderedKeys(lockFile.packages):
      let pkg = lockFile.packages[key]
      graph["nodes"].add(%*{"id": "dep:" & key, "kind": "dependency",
        "name": pkg.id.name, "version": pkg.id.version,
        "source": pkg.id.source, "direct": pkg.direct})
      seen[key] = true
    for key in sortedOrderedKeys(lockFile.packages):
      let pkg = lockFile.packages[key]
      for edge in pkg.dependencies:
        if edge.package.len > 0 and seen.hasKey(edge.package):
          graph["edges"].add(%*{"from": "dep:" & key,
            "to": "dep:" & edge.package, "kind": "dependency"})
    graph["lock"] = %*{"version": lockFile.version,
      "resolver": lockFile.resolver}
  except CatchableError as e:
    graph["lock"] = %*{"error": e.msg}

proc dedupeGraph(graph: var JsonNode) =
  var seenNodes = initHashSet[string]()
  var nodes = newJArray()
  for node in graph["nodes"].getElems():
    let id = node["id"].getStr()
    if not seenNodes.contains(id):
      nodes.add(node)
      seenNodes.incl(id)
  graph["nodes"] = nodes

  var seenEdges = initHashSet[string]()
  var edges = newJArray()
  for edge in graph["edges"].getElems():
    let key = edge["from"].getStr() & "\t" & edge["to"].getStr() & "\t" &
      edge["kind"].getStr()
    if not seenEdges.contains(key):
      edges.add(edge)
      seenEdges.incl(key)
  graph["edges"] = edges

proc graphJson*(cfg: BauConfig; projectDir: string = ""): JsonNode =
  ## Build a graph of targets, tasks, build scripts, features, and dependencies.
  ##
  ## When `projectDir` is supplied, resolved lockfile dependency nodes are
  ## included as well.
  result = newJObject()
  var nodes = newJArray()
  var edges = newJArray()
  var seenNodes = initHashSet[string]()
  var seenEdges = initHashSet[string]()

  proc addNode(node: JsonNode) =
    let id = node["id"].getStr()
    if not seenNodes.contains(id):
      nodes.add(node)
      seenNodes.incl(id)

  proc addEdge(edge: JsonNode) =
    let key = edge["from"].getStr() & "\t" & edge["to"].getStr() & "\t" &
      edge["kind"].getStr()
    if not seenEdges.contains(key):
      edges.add(edge)
      seenEdges.incl(key)

  let buildName = defaultTargetName(cfg)
  addNode(%*{"id": "target:" & buildName, "kind": "target",
    "name": buildName, "main": cfg.build.main, "output": cfg.build.output})
  for target in cfg.targets:
    addNode(%*{"id": "target:" & target.name, "kind": "target",
      "name": target.name, "main": target.main, "output": target.output,
      "profile": target.profile})
  for task in cfg.tasks:
    addNode(%*{"id": "task:" & task.name, "kind": "task",
      "name": task.name, "cmd": task.cmd, "command": task.command})
    for dep in task.deps:
      let targetId = if dep == "build": "target:" & buildName else: "task:" & dep
      addEdge(%*{"from": "task:" & task.name, "to": targetId,
        "kind": "task-dep"})
  for script in cfg.buildScripts:
    addNode(%*{"id": "build-script:" & script.name, "kind": "build-script",
      "name": script.name, "cmd": script.cmd})
    addEdge(%*{"from": "target:" & buildName,
      "to": "build-script:" & script.name, "kind": "build-script"})
  for name in sortedKeys(cfg.deps):
    addNode(%*{"id": "dep:" & name, "kind": "dependency"})
    addEdge(%*{"from": "target:" & buildName, "to": "dep:" & name,
      "kind": "target-dep"})
    for target in cfg.targets:
      addEdge(%*{"from": "target:" & target.name, "to": "dep:" & name,
        "kind": "target-dep"})
  for name in sortedKeys(cfg.features):
    addNode(%*{"id": "feature:" & name, "kind": "feature"})
    for item in cfg.features[name].enables:
      let dest = if item.startsWith("dep:"):
                   "dep:" & item["dep:".len..^1]
                 elif cfg.features.hasKey(item):
                   "feature:" & item
                 else:
                   "dep:" & item
      addEdge(%*{"from": "feature:" & name, "to": dest,
        "kind": "feature-enables"})

  result["nodes"] = nodes
  result["edges"] = edges
  if projectDir.len > 0:
    result.addResolvedGraph(projectDir)
    result.dedupeGraph()

proc graphDot*(cfg: BauConfig; projectDir: string = ""): string =
  ## Render Bau's project graph as Graphviz DOT.
  result = "digraph bau {\n"
  result.add("  rankdir=LR;\n")
  let graph = graphJson(cfg, projectDir)
  for node in graph["nodes"].getElems():
    result.add("  \"" & node["id"].getStr() & "\";\n")
  for edge in graph["edges"].getElems():
    result.add("  \"" & edge["from"].getStr() & "\" -> \"" &
      edge["to"].getStr() & "\";\n")
  result.add("}\n")

proc queryDeps*(cfg: BauConfig; name: string): seq[string] =
  ## Return configured direct dependencies for a task, script, target, or package.
  for task in cfg.tasks:
    if task.name == name:
      return task.deps
  for script in cfg.buildScripts:
    if script.name == name:
      return script.deps
  if name.len == 0 or name == cfg.package.name or name == cfg.build.output or
      name == defaultTargetName(cfg):
    for dep in sortedKeys(cfg.deps):
      result.add(dep)
  else:
    for target in cfg.targets:
      if target.name == name:
        for dep in sortedKeys(cfg.deps):
          result.add(dep)
        return

proc queryResolvedDeps*(projectDir: string; name: string): seq[string] =
  ## Return dependencies recorded in `bau.lock` for a locked package.
  if not fileExists(projectDir / LockFileName):
    return
  let lockFile = parseLockFile(projectDir / LockFileName)
  for key in sortedOrderedKeys(lockFile.packages):
    let pkg = lockFile.packages[key]
    if name.len == 0 or pkg.id.name == name or key == name:
      for edge in pkg.dependencies:
        if edge.name.len > 0:
          result.add(edge.name)
      result.sort()
      return
  if name.len == 0:
    for key in sortedOrderedKeys(lockFile.packages):
      result.add(lockFile.packages[key].id.name)

proc queryResolvedWhy*(projectDir, depName: string): string =
  ## Explain why a dependency appears in the resolved lockfile.
  if not fileExists(projectDir / LockFileName):
    return ""
  let lockFile = parseLockFile(projectDir / LockFileName)
  for key in sortedOrderedKeys(lockFile.packages):
    let pkg = lockFile.packages[key]
    if pkg.id.name == depName:
      if pkg.direct:
        result = depName & " is a direct package dependency locked from " &
          pkg.id.source
      else:
        result = depName & " is a transitive package dependency locked from " &
          pkg.id.source
      return
    for edge in pkg.dependencies:
      if edge.name == depName:
        result = depName & " is required by " & pkg.id.name
        return

proc queryWhy*(cfg: BauConfig; depName: string): string =
  ## Explain why a direct dependency or feature appears in configuration.
  if cfg.deps.hasKey(depName):
    result = depName & " is a direct package dependency"
    if cfg.patches.hasKey(depName):
      result.add(" patched by [patch]." & depName)
    if cfg.deps[depName].optional:
      var features: seq[string]
      for name in sortedKeys(cfg.features):
        for item in cfg.features[name].enables:
          if item == "dep:" & depName or item == depName:
            features.add(name)
      if features.len > 0:
        result.add(" enabled by feature(s): " & features.join(", "))
      else:
        result.add(" and is optional but no feature enables it")
  else:
    var featureNames: seq[string]
    for name in sortedKeys(cfg.features):
      if name == depName:
        featureNames.add(name)
    if featureNames.len > 0:
      result = depName & " is a feature"
    else:
      result = depName & " is not present in the direct dependency set"

proc buildStatusJson*(cfg: BauConfig; projectDir: string;
    profile: string): JsonNode =
  ## Build JSON describing the saved fingerprint status for the default target.
  let outName = if cfg.build.output.len >
      0: cfg.build.output else: cfg.package.name
  let fpDir = absolutePath(projectDir) / BuildDirName / FingerprintDirName
  let saved = loadFingerprint(fpDir, outName, "main")
  result = newJObject()
  result["target"] = %outName
  result["profile"] = %profile
  result["cached"] = %saved.isSome
  if saved.isSome:
    result["fingerprint"] = parseJson(toJson(saved.get()))
