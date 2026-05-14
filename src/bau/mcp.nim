## Serves Bau operations over the Model Context Protocol.

import std/[json, os, streams, options, strutils]
import bau/[util, config, metadata, ops]

proc respond(id: JsonNode; res, err: JsonNode): string =
  var node = newJObject()
  node["jsonrpc"] = %"2.0"
  node["id"] = if id == nil: newJNull() else: id
  if res != nil:
    node["result"] = res
  if err != nil:
    node["error"] = err
  $node

proc respondOk(id: JsonNode; res: JsonNode): string =
  respond(id, res, nil)

proc respondErr(id: JsonNode; code: int; message: string): string =
  var err = newJObject()
  err["code"] = %code
  err["message"] = %message
  respond(id, nil, err)

proc handleInitialize(id: JsonNode; params: JsonNode): string =
  discard params
  var r = newJObject()
  r["protocolVersion"] = %"2024-11-05"
  r["serverInfo"] = %*{"name": %"bau", "version": %BauVersion}
  r["capabilities"] = %*{"tools": %*{}, "resources": %*{}}
  respondOk(id, r)

proc toolsList(): JsonNode =
  var tools = newJArray()
  tools.add(%*{
    "name": "bau_build",
    "description": "Compile the Nim project",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "description": "Build profile: dev, release, test",
            "default": "dev"},
        "verbose": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_run",
    "description": "Build and run a binary target",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"},
        "args": {"type": "array", "items": {"type": "string"},
            "description": "Arguments to pass to the binary"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_test",
    "description": "Build and run tests",
    "inputSchema": {
      "type": "object",
      "properties": {
        "filter": {"type": "string", "description": "Filter test files by name"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_check",
    "description": "Type-check without producing binary",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_doc",
    "description": "Generate indexed API documentation from Nim source",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"},
        "outDir": {"type": "string", "description": "Documentation output directory"},
        "entrypoints": {"type": "array", "items": {"type": "string"}},
        "skipExamples": {"type": "boolean", "default": false},
        "includePrivate": {"type": "boolean", "default": false},
        "noIndex": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_clean",
    "description": "Remove build artifacts",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_install",
    "description": "Install, update, or remove project binaries",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["install", "update", "remove"],
            "default": "install"},
        "target": {"type": "string", "description": "Target name"},
        "profile": {"type": "string", "default": "dev"},
        "installDir": {"type": "string",
            "description": "Destination directory"},
        "allTargets": {"type": "boolean", "default": false},
        "force": {"type": "boolean", "default": false},
        "dryRun": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_deps",
    "description": "Sync or update dependencies",
    "inputSchema": {
      "type": "object",
      "properties": {
        "update": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_add",
    "description": "Add a dependency to bau.toml",
    "inputSchema": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": {"type": "string", "description": "Dependency name"},
        "version": {"type": "string", "description": "Version requirement"},
        "git": {"type": "string", "description": "Git URL"},
        "tag": {"type": "string", "description": "Git tag"},
        "branch": {"type": "string", "description": "Git branch"},
        "rev": {"type": "string", "description": "Git revision"},
        "path": {"type": "string", "description": "Local path"},
        "registry": {"type": "string", "description": "Registry name"},
        "optional": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_remove",
    "description": "Remove a dependency from bau.toml",
    "inputSchema": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": {"type": "string", "description": "Dependency name"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_init",
    "description": "Initialize a bau project in a directory",
    "inputSchema": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": {"type": "string"},
        "kind": {"type": "string", "enum": ["bin", "lib"], "default": "bin"},
        "dir": {"type": "string", "description": "Directory path"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_convert",
    "description": "Convert an existing .nimble project to bau.toml",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Package directory or .nimble file"},
        "dryRun": {"type": "boolean", "default": true},
        "force": {"type": "boolean", "default": false}
    }
  }
  })
  tools.add(%*{
    "name": "bau_fmt",
    "description": "Format Nim source files",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_explain",
    "description": "Show what changed since last build",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_compile_commands",
    "description": "Generate compile_commands.json for LSP",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"},
        "features": {"type": "array", "items": {"type": "string"}},
        "allFeatures": {"type": "boolean", "default": false},
        "noDefaultFeatures": {"type": "boolean", "default": false},
        "jobs": {"type": "integer"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_metadata",
    "description": "Return machine-readable project metadata",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_graph",
    "description": "Return the project graph",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_query",
    "description": "Run graph/dependency queries",
    "inputSchema": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": {"type": "string", "enum": ["deps", "why"]},
        "name": {"type": "string"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_affected",
    "description": "Return changed files and affected work",
    "inputSchema": {
      "type": "object",
      "properties": {
        "since": {"type": "string", "default": "HEAD"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_cache_explain",
    "description": "Explain a task cache key and hit state",
    "inputSchema": {
      "type": "object",
      "required": ["task"],
      "properties": {
        "task": {"type": "string"},
        "profile": {"type": "string", "default": "dev"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_deps_verify",
    "description": "Verify dependency policy and lock freshness",
    "inputSchema": {"type": "object", "properties": {}}
  })
  result = %*{"tools": tools}

proc operationOptions(args: JsonNode): OperationOptions =
  result = defaultOperationOptions()
  result.profile = args{"profile"}.getStr("dev")
  result.since = args{"since"}.getStr("HEAD")
  result.allFeatures = args{"allFeatures"}.getBool(false)
  result.noDefaultFeatures = args{"noDefaultFeatures"}.getBool(false)
  if args.hasKey("features") and args["features"].kind == JArray:
    for item in args["features"].getElems():
      result.features.add(item.getStr())
  if args.hasKey("task"):
    result.taskName = args["task"].getStr()
  if args.hasKey("kind"):
    result.queryKind = args["kind"].getStr()
  if args.hasKey("name"):
    result.queryName = args["name"].getStr()
    result.depName = args["name"].getStr()
    result.initName = args["name"].getStr()
  result.depVersion = args{"version"}.getStr("")
  if args.hasKey("args") and args["args"].kind == JArray:
    for item in args["args"].getElems():
      result.runArgs.add(item.getStr())
  result.filter = args{"filter"}.getStr("")
  result.precise = args{"precise"}.getStr("")
  result.verbose = args{"verbose"}.getBool(false)
  result.allTargets = args{"allTargets"}.getBool(false)
  result.update = args{"update"}.getBool(false)
  result.force = args{"force"}.getBool(false)
  result.dryRun = args{"dryRun"}.getBool(false)
  result.targetName = args{"target"}.getStr("")
  result.installAction = args{"action"}.getStr("")
  result.installDir = args{"installDir"}.getStr("")
  result.depGit = args{"git"}.getStr("")
  result.depTag = args{"tag"}.getStr("")
  result.depBranch = args{"branch"}.getStr("")
  result.depRev = args{"rev"}.getStr("")
  result.depPath = args{"path"}.getStr("")
  result.depRegistry = args{"registry"}.getStr("")
  result.depOptional = args{"optional"}.getBool(false)
  result.initKind = args{"kind"}.getStr("bin")
  result.initDir = args{"dir"}.getStr("")
  result.convertPath = args{"path"}.getStr("")
  result.docOutDir = args{"outDir"}.getStr("")
  if args.hasKey("entrypoints") and args["entrypoints"].kind == JArray:
    for item in args["entrypoints"].getElems():
      result.docEntrypoints.add(item.getStr())
  result.docSkipExamples = args{"skipExamples"}.getBool(false)
  result.docIncludePrivate = args{"includePrivate"}.getBool(false)
  result.docNoIndex = args{"noIndex"}.getBool(false)

proc resourcesList(projectDir: string): JsonNode =
  discard projectDir
  var resources = newJArray()
  resources.add(%*{
    "uri": "bau://config",
    "name": "Project configuration",
    "description": "Merged effective bau.toml configuration",
    "mimeType": "application/json"
  })
  resources.add(%*{
    "uri": "bau://targets",
    "name": "Build targets",
    "description": "List of build targets with profiles",
    "mimeType": "application/json"
  })
  resources.add(%*{
    "uri": "bau://deps",
    "name": "Dependencies",
    "description": "Dependency tree with versions",
    "mimeType": "application/json"
  })
  resources.add(%*{
    "uri": "bau://tasks",
    "name": "Custom tasks",
    "description": "Available custom tasks from bau.toml",
    "mimeType": "application/json"
  })
  resources.add(%*{
    "uri": "bau://status",
    "name": "Build status",
    "description": "Build status (dirty/clean per target)",
    "mimeType": "application/json"
  })
  result = %*{"resources": resources}

proc targetResources(cfg: BauConfig): JsonNode =
  var targets = newJArray()
  let buildName = defaultTargetName(cfg)
  targets.add(%*{
    "name": buildName,
    "kind": $cfg.build.kind,
    "main": cfg.build.main,
    "output": cfg.build.output,
    "profile": "",
    "requiredFeatures": [],
    "tags": []
  })
  for target in cfg.targets:
    targets.add(%*{
      "name": target.name,
      "kind": $target.kind,
      "main": target.main,
      "output": target.output,
      "profile": target.profile,
      "requiredFeatures": target.requiredFeatures,
      "tags": target.tags
    })
  %*{"package": cfg.package.name, "targets": targets}

proc dependencyResources(cfg: BauConfig; projectDir: string): JsonNode =
  let metadata = configMetadataJson(cfg, projectDir)
  result = %*{
    "dependencies": metadata["dependencies"],
    "sources": metadata["sources"],
    "patches": metadata["patches"],
    "tree": dependencyTreeJson(cfg, projectDir),
    "status": dependencyStatusJson(cfg, projectDir)
  }
  if metadata.hasKey("resolvedDependencies"):
    result["resolvedDependencies"] = metadata["resolvedDependencies"]
  if metadata.hasKey("lock"):
    result["lock"] = metadata["lock"]

proc taskResources(cfg: BauConfig): JsonNode =
  var tasks = newJArray()
  for task in cfg.tasks:
    tasks.add(%*{
      "name": task.name,
      "cmd": task.cmd,
      "command": task.command,
      "description": task.description,
      "deps": task.deps,
      "inputs": task.inputs,
      "outputs": task.outputs,
      "cwd": if task.cwd.isSome: task.cwd.get() else: "",
      "shell": task.shell,
      "profile": task.profile,
      "envInputs": task.envInputs,
      "cache": task.cache,
      "acceptArgs": task.acceptArgs,
      "requiredFeatures": task.requiredFeatures,
      "tags": task.tags
    })
  var buildScripts = newJArray()
  for script in cfg.buildScripts:
    buildScripts.add(%*{
      "name": script.name,
      "cmd": script.cmd,
      "deps": script.deps,
      "inputs": script.inputs,
      "outputs": script.outputs,
      "envInputs": script.envInputs
    })
  %*{"tasks": tasks, "buildScripts": buildScripts}

proc readResource(uri: string; projectDir: string): OperationResult =
  try:
    if not fileExists(projectDir / ConfigFileName):
      return OperationResult(ok: false, json: %*{"error": "no bau.toml found"})
    let cfg = loadEffectiveConfig(projectDir)
    case uri
    of "bau://config":
      resultJson(configMetadataJson(cfg, projectDir))
    of "bau://targets":
      resultJson(targetResources(cfg))
    of "bau://deps":
      resultJson(dependencyResources(cfg, projectDir))
    of "bau://tasks":
      resultJson(taskResources(cfg))
    of "bau://status":
      resultJson(buildStatusJson(cfg, projectDir, "dev"))
    else:
      OperationResult(ok: false, json: %*{"error": "unknown resource: " & uri})
  except CatchableError as e:
    OperationResult(ok: false, json: %*{"error": e.msg})

proc handleToolsList(id: JsonNode): string =
  respondOk(id, toolsList())

proc handleResourcesList(id: JsonNode; projectDir: string): string =
  respondOk(id, resourcesList(projectDir))

proc handleResourcesRead(id: JsonNode; params: JsonNode;
    projectDir: string): string =
  let uri = params{"uri"}.getStr("")
  if uri.len == 0:
    return respondErr(id, -32602, "missing uri parameter")
  let op = readResource(uri, projectDir)
  if not op.ok:
    return respondErr(id, -32000, op.json{"error"}.getStr("resource error"))
  var contents = newJObject()
  contents["contents"] = %*[{"uri": %uri, "mimeType": %"application/json",
    "text": %($op.json)}]
  respondOk(id, contents)

proc toolError(message: string): OperationResult =
  OperationResult(ok: false, json: %*{"error": message}, output: message)

proc execTool(name: string; args: JsonNode;
    projectDir: string): OperationResult =
  let opts = operationOptions(args)

  case name
  of "bau_build":
    result = buildOperation(projectDir, opts)

  of "bau_run":
    result = runOperation(projectDir, opts)

  of "bau_test":
    result = testOperation(projectDir, opts)

  of "bau_check":
    result = checkOperation(projectDir, opts)

  of "bau_doc":
    result = docOperation(projectDir, opts)

  of "bau_clean":
    result = cleanOperation(projectDir, opts)

  of "bau_install":
    result = installOperation(projectDir, opts)

  of "bau_deps":
    result = depsOperation(projectDir, opts)

  of "bau_add":
    result = addDependencyOperation(projectDir, opts)

  of "bau_remove":
    result = removeDependencyOperation(projectDir, opts)

  of "bau_init":
    result = initOperation(projectDir, opts)

  of "bau_convert":
    var convertOpts = opts
    if not args.hasKey("dryRun"):
      convertOpts.dryRun = true
    result = convertOperation(projectDir, convertOpts)

  of "bau_fmt":
    result = fmtOperation(projectDir, opts)

  of "bau_explain":
    result = explainOperation(projectDir, opts)

  of "bau_compile_commands":
    result = compileCommandsOperation(projectDir, operationOptions(args))

  of "bau_metadata":
    result = metadataOperation(projectDir, operationOptions(args))

  of "bau_graph":
    result = graphOperation(projectDir, operationOptions(args))

  of "bau_query":
    result = queryOperation(projectDir, operationOptions(args))

  of "bau_affected":
    result = affectedOperation(projectDir, operationOptions(args))

  of "bau_cache_explain":
    result = cacheExplainOperation(projectDir, operationOptions(args))

  of "bau_deps_verify":
    result = depsVerifyOperation(projectDir, operationOptions(args))

  else:
    result = toolError("unknown tool: " & name)

proc handleToolsCall(id: JsonNode; params: JsonNode;
    projectDir: string): string =
  let name = params{"name"}.getStr("")
  if name.len == 0:
    return respondErr(id, -32602, "missing name parameter")

  let argsNode = params{"arguments"}
  let args = if argsNode == nil: newJObject() else: argsNode
  if args.kind != JObject:
    return respondErr(id, -32602, "arguments must be an object")

  try:
    let op = execTool(name, args, projectDir)
    var content = newJArray()
    content.add(%*{"type": "text", "text": $op.json})
    var response = newJObject()
    response["content"] = content
    if not op.ok:
      response["isError"] = %true
    respondOk(id, response)
  except CatchableError as e:
    respondErr(id, -32000, "tool execution failed: " & e.msg)

proc handleRequest*(line: string; projectDir: string): string =
  ## Handle one JSON-RPC request body for Bau's MCP server.
  ##
  ## Notifications return an empty string because they do not produce responses.
  try:
    let msg = parseJson(line)
    let hasId = msg.hasKey("id")
    let id = if hasId: msg["id"] else: nil
    let reqMethod = msg{"method"}.getStr("")
    let params = msg{"params"}

    if not hasId:
      return ""

    case reqMethod
    of "initialize":
      result = handleInitialize(id, params)
    of "tools/list":
      result = handleToolsList(id)
    of "tools/call":
      result = handleToolsCall(id, params, projectDir)
    of "resources/list":
      result = handleResourcesList(id, projectDir)
    of "resources/read":
      result = handleResourcesRead(id, params, projectDir)
    of "notifications/initialized":
      result = ""
    else:
      if reqMethod.startsWith("notifications/"):
        result = ""
      else:
        result = respondErr(id, -32601, "unknown method: " & reqMethod)
  except CatchableError as e:
    result = respondErr(newJNull(), -32700, "parse error: " & e.msg)

proc parseContentLength(line: string): int =
  let cleaned = line.strip()
  if not cleaned.toLowerAscii().startsWith("content-length:"):
    return -1
  let parts = cleaned.split(":", 1)
  if parts.len != 2:
    raise newException(ValueError, "invalid MCP Content-Length header")
  try:
    result = parseInt(parts[1].strip())
  except ValueError:
    raise newException(ValueError, "invalid MCP Content-Length value")
  if result < 0:
    raise newException(ValueError, "negative MCP Content-Length value")

proc readMcpMessage*(input: Stream): string =
  ## Read one MCP message from a stream.
  ##
  ## Supports both standard `Content-Length` framing and bare JSON lines.
  while not input.atEnd:
    var line = ""
    if not input.readLine(line):
      return ""
    let first = line.strip()
    if first.len > 0:
      if first.startsWith("{") or first.startsWith("["):
        return first

      let bodyLen = parseContentLength(first)
      if bodyLen < 0:
        raise newException(ValueError, "expected MCP Content-Length header")
      while true:
        var header = ""
        if not input.readLine(header):
          raise newException(IOError, "truncated MCP headers")
        if header.strip().len == 0:
          break
      result = input.readStr(bodyLen)
      if result.len != bodyLen:
        raise newException(IOError, "truncated MCP message body")
      return

proc formatMcpResponse*(response: string): string =
  ## Wrap a JSON-RPC response body in MCP `Content-Length` framing.
  if response.len == 0:
    return ""
  "Content-Length: " & $response.len & "\r\n\r\n" & response

proc mcpServerLoop*(projectDir: string) =
  ## Run the stdio MCP server loop for a project directory.
  let input = newFileStream(stdin)
  while not input.atEnd:
    try:
      let message = readMcpMessage(input)
      if message.len > 0:
        let response = handleRequest(message, projectDir)
        if response.len > 0:
          stdout.write(formatMcpResponse(response))
          flushFile(stdout)
    except CatchableError as e:
      stdout.write(formatMcpResponse(respondErr(newJNull(), -32700,
        "parse error: " & e.msg)))
      flushFile(stdout)
