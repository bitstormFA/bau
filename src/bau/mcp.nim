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
        "target": {"type": "string", "description": "Target name"},
        "allTargets": {"type": "boolean", "default": false},
        "features": {"type": "array", "items": {"type": "string"}},
        "allFeatures": {"type": "boolean", "default": false},
        "noDefaultFeatures": {"type": "boolean", "default": false},
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
        "target": {"type": "string", "description": "Target name"},
        "args": {"type": "array", "items": {"type": "string"},
            "description": "Arguments to pass to the binary"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_test",
    "description": "Validate the project against the Test Plan",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"},
        "filter": {"type": "string", "description": "Filter test files by name"},
        "changed": {"type": "boolean", "default": false},
        "full": {"type": "boolean", "default": false},
        "fast": {"type": "boolean", "default": false},
        "noMatrix": {"type": "boolean", "default": false},
        "noRunner": {"type": "boolean", "default": false},
        "showOutput": {"type": "string", "enum": ["auto", "always", "never"]},
        "dryRun": {"type": "boolean", "default": false},
        "jobs": {"type": "integer"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_check",
    "description": "Type-check without producing binary",
    "inputSchema": {
      "type": "object",
      "properties": {
        "profile": {"type": "string", "default": "dev"},
        "target": {"type": "string", "description": "Target name"},
        "allTargets": {"type": "boolean", "default": false}
    }
  }
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
    "description": "Remove Bau Outputs",
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
    "description": "Run dependency sync, lock, update, verify, vendor, or patch",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {"type": "string",
            "enum": ["sync", "lock", "update", "verify", "vendor", "patch"],
            "default": "sync"},
        "name": {"type": "string", "description": "Dependency name for update or patch"},
        "path": {"type": "string", "description": "Patch path for action=patch"},
        "precise": {"type": "string", "description": "Exact revision for update"},
        "offline": {"type": "boolean", "default": false},
        "locked": {"type": "boolean", "default": false},
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
    "name": "bau_lint",
    "description": "Validate Nim source style without rewriting files",
    "inputSchema": {"type": "object", "properties": {
      "verbose": {"type": "boolean", "default": false}
    }}
  })
  tools.add(%*{
    "name": "bau_ci",
    "description": "Run validation-oriented CI checks",
    "inputSchema": {"type": "object", "properties": {
      "profile": {"type": "string", "default": "dev"},
      "verbose": {"type": "boolean", "default": false}
    }}
  })
  tools.add(%*{
    "name": "bau_task",
    "description": "List or run a declared Bau task",
    "inputSchema": {
      "type": "object",
      "properties": {
        "list": {"type": "boolean", "default": false},
        "name": {"type": "string", "description": "Task name"},
        "args": {"type": "array", "items": {"type": "string"}},
        "profile": {"type": "string", "default": "dev"},
        "dryRun": {"type": "boolean", "default": false},
        "force": {"type": "boolean", "default": false},
        "keepGoing": {"type": "boolean", "default": false}
    }
  }
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
    "description": "List or run work affected by Git changes",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["list", "check", "test", "build"],
            "default": "list"},
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
  tools.add(%*{
    "name": "bau_cache",
    "description": "List, clean, or explain task cache entries",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["list", "clean", "explain"],
            "default": "list"},
        "task": {"type": "string"},
        "profile": {"type": "string", "default": "dev"}
    }
  }
  })
  tools.add(%*{
    "name": "bau_tree",
    "description": "Return dependency tree data",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_outdated",
    "description": "Return dependency status data",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_tailor",
    "description": "Discover or write missing target declarations",
    "inputSchema": {"type": "object", "properties": {
      "write": {"type": "boolean", "default": false}
    }}
  })
  tools.add(%*{
    "name": "bau_package",
    "description": "Validate Package Contents and optionally write package manifest output",
    "inputSchema": {"type": "object", "properties": {
      "list": {"type": "boolean", "default": false},
      "dryRun": {"type": "boolean", "default": true}
    }}
  })
  tools.add(%*{
    "name": "bau_publish",
    "description": "Validate or submit a Package Publication",
    "inputSchema": {"type": "object", "properties": {
      "dryRun": {"type": "boolean", "default": true}
    }}
  })
  tools.add(%*{
    "name": "bau_bump",
    "description": "Increment Package version intent",
    "inputSchema": {"type": "object", "required": ["kind"], "properties": {
      "kind": {"type": "string", "enum": ["major", "minor", "patch"]},
      "dryRun": {"type": "boolean", "default": true}
    }}
  })
  tools.add(%*{
    "name": "bau_ci_template",
    "description": "Write CI template files",
    "inputSchema": {"type": "object", "properties": {
      "kind": {"type": "string", "enum": ["github", "gitlab"],
          "default": "github"}
    }}
  })
  tools.add(%*{
    "name": "bau_env",
    "description": "Return resolved Build Environment details",
    "inputSchema": {"type": "object", "properties": {
      "profile": {"type": "string", "default": "dev"},
      "features": {"type": "array", "items": {"type": "string"}},
      "allFeatures": {"type": "boolean", "default": false},
      "noDefaultFeatures": {"type": "boolean", "default": false}
    }}
  })
  tools.add(%*{
    "name": "bau_doctor",
    "description": "Check configured toolchain requirements",
    "inputSchema": {"type": "object", "properties": {}}
  })
  tools.add(%*{
    "name": "bau_shell_init",
    "description": "Add Bau's binary directory to shell startup state",
    "inputSchema": {"type": "object", "properties": {
      "shell": {"type": "string", "description": "bash, zsh, fish, or sh"}
    }}
  })
  tools.add(%*{
    "name": "bau_mcp_setup",
    "description": "Register Bau MCP and local skills for coding agents",
    "inputSchema": {"type": "object", "properties": {
      "targets": {"type": "array", "items": {
        "type": "string", "enum": ["codex", "claude", "copilot"]
      }},
      "force": {"type": "boolean", "default": false},
      "dryRun": {"type": "boolean", "default": false}
    }}
  })
  tools.add(%*{
    "name": "bau_new",
    "description": "Create a new Bau project directory",
    "inputSchema": {"type": "object", "required": ["path"], "properties": {
      "path": {"type": "string"},
      "name": {"type": "string"},
      "kind": {"type": "string", "enum": ["bin", "lib"], "default": "bin"},
      "force": {"type": "boolean", "default": false}
    }}
  })
  result = %*{"tools": tools}

proc operationOptions(args: JsonNode): OperationOptions =
  result = defaultOperationOptions()
  result.profile = args{"profile"}.getStr("dev")
  result.since = args{"since"}.getStr("HEAD")
  result.allFeatures = args{"allFeatures"}.getBool(false)
  result.noDefaultFeatures = args{"noDefaultFeatures"}.getBool(false)
  result.jobs = args{"jobs"}.getInt(0)
  result.jobsExplicit = args.hasKey("jobs")
  if args.hasKey("features") and args["features"].kind == JArray:
    for item in args["features"].getElems():
      result.features.add(item.getStr())
  if args.hasKey("task"):
    result.taskName = args["task"].getStr()
  if result.taskName.len == 0 and args.hasKey("name"):
    result.taskName = args["name"].getStr()
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
      result.taskArgs.add(item.getStr())
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
  result.depsAction = args{"action"}.getStr("")
  result.cacheAction = args{"action"}.getStr("")
  result.affectedAction = args{"action"}.getStr("")
  result.list = args{"list"}.getBool(false)
  result.write = args{"write"}.getBool(false)
  result.keepGoing = args{"keepGoing"}.getBool(false)
  result.offline = args{"offline"}.getBool(false)
  result.locked = args{"locked"}.getBool(false)
  result.bumpKind = args{"kind"}.getStr("")
  result.ciKind = args{"kind"}.getStr("")
  result.shellName = args{"shell"}.getStr("")
  result.testChanged = args{"changed"}.getBool(false)
  result.testFull = args{"full"}.getBool(false)
  result.testFast = args{"fast"}.getBool(false)
  result.testNoMatrix = args{"noMatrix"}.getBool(false)
  result.testNoRunner = args{"noRunner"}.getBool(false)
  result.testShowOutput = args{"showOutput"}.getStr("")
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
  if args.hasKey("targets") and args["targets"].kind == JArray:
    for item in args["targets"].getElems():
      result.agentTargets.add(item.getStr())

proc resourcesList(projectDir: string): JsonNode =
  discard projectDir
  var resources = newJArray()
  resources.add(%*{
    "uri": "bau://manifest",
    "name": "Project Manifest",
    "description": "Effective Project Manifest metadata",
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
    of "bau://manifest":
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

  of "bau_new":
    var newOpts = opts
    newOpts.initDir = args{"path"}.getStr("")
    if newOpts.initDir.len == 0:
      return toolError("path is required")
    if newOpts.initName.len == 0:
      newOpts.initName = extractFilename(newOpts.initDir)
    result = initOperation(projectDir, newOpts)

  of "bau_convert":
    var convertOpts = opts
    if not args.hasKey("dryRun"):
      convertOpts.dryRun = true
    result = convertOperation(projectDir, convertOpts)

  of "bau_fmt":
    result = fmtOperation(projectDir, opts)

  of "bau_lint":
    result = lintOperation(projectDir, opts)

  of "bau_ci":
    result = ciOperation(projectDir, opts)

  of "bau_task":
    result = taskOperation(projectDir, opts)

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

  of "bau_cache":
    result = cacheOperation(projectDir, operationOptions(args))

  of "bau_tree":
    result = dependencyTreeOperation(projectDir, operationOptions(args))

  of "bau_outdated":
    result = dependencyStatusOperation(projectDir, operationOptions(args))

  of "bau_tailor":
    result = tailorOperation(projectDir, operationOptions(args))

  of "bau_package":
    var packageOpts = operationOptions(args)
    if not args.hasKey("dryRun"):
      packageOpts.dryRun = true
    result = packageOperation(projectDir, packageOpts)

  of "bau_publish":
    var publishOpts = operationOptions(args)
    if not args.hasKey("dryRun"):
      publishOpts.dryRun = true
    result = publishOperation(projectDir, publishOpts)

  of "bau_bump":
    var bumpOpts = operationOptions(args)
    if not args.hasKey("dryRun"):
      bumpOpts.dryRun = true
    result = bumpOperation(projectDir, bumpOpts)

  of "bau_ci_template":
    result = ciTemplateOperation(projectDir, operationOptions(args))

  of "bau_env":
    result = envOperation(projectDir, operationOptions(args))

  of "bau_doctor":
    result = doctorOperation(projectDir, operationOptions(args))

  of "bau_shell_init":
    result = shellInitOperation(projectDir, operationOptions(args))

  of "bau_mcp_setup":
    result = agentSetupOperation(projectDir, operationOptions(args))

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
  ## Supports MCP's newline-delimited JSON messages and legacy
  ## `Content-Length` framed messages.
  while not input.atEnd:
    var line = ""
    if not input.readLine(line):
      return ""
    let first = line.strip()
    if first.len > 0:
      if first.startsWith("{") or first.startsWith("["):
        return first

      var bodyLen = parseContentLength(first)
      while true:
        var header = ""
        if not input.readLine(header):
          raise newException(IOError, "truncated MCP headers")
        let cleaned = header.strip()
        if cleaned.len == 0:
          break
        let headerBodyLen = parseContentLength(cleaned)
        if headerBodyLen >= 0:
          bodyLen = headerBodyLen
      if bodyLen < 0:
        raise newException(ValueError, "expected MCP Content-Length header")
      result = input.readStr(bodyLen)
      if result.len != bodyLen:
        raise newException(IOError, "truncated MCP message body")
      return

proc formatMcpResponse*(response: string): string =
  ## Format a JSON-RPC response body as one MCP stdio message.
  if response.len == 0:
    return ""
  response & "\n"

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
