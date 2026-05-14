## Implements Bau's command-line parser and command handlers.

import std/[algorithm, os, osproc, strutils, options, sets, tables, times,
  monotimes, json]
import bau/[argv, util, config, init, build, atlas, nimble,
  ci_templates, lock, metadata, packaging, tailor, taskgraph, features,
  affected, depscheck, taskcache, testexec, toolchain, workspace, ops,
  configedit, installer]
when defined(linux):
  import posix/inotify
  import std/posix except Time

type
  Command* = enum      ## Parsed CLI command.
    cmdNone            ## No command was selected.
    cmdBuild           ## Build project targets.
    cmdRun             ## Build and run a target.
    cmdTest            ## Run tests.
    cmdCheck           ## Type-check configured targets.
    cmdDoc             ## Generate API documentation.
    cmdInstall         ## Install a built binary.
    cmdUpdate          ## Update an installed binary.
    cmdUninstall       ## Remove an installed binary.
    cmdClean           ## Remove build artifacts.
    cmdDeps            ## Manage dependencies.
    cmdAdd             ## Add a dependency.
    cmdRemove          ## Remove a dependency.
    cmdInit            ## Initialize the current directory.
    cmdNew             ## Create a new project directory.
    cmdConvert         ## Convert a Nimble project.
    cmdVersion         ## Print version information.
    cmdHelp            ## Print help text.
    cmdTask            ## Run a custom task.
    cmdFmt             ## Format source files.
    cmdLint            ## Run style checks.
    cmdCi              ## Run the local CI sequence.
    cmdOutdated        ## Report dependency status.
    cmdTree            ## Print dependency tree output.
    cmdExplain         ## Explain build cache state.
    cmdPublish         ## Publish package metadata.
    cmdBump            ## Increment the project package version.
    cmdShell           ## Open a shell with Bau environment.
    cmdShellInit       ## Add Bau's binary directory to the selected shell.
    cmdPlugin          ## Delegate to an external `bau-*` plugin.
    cmdCompileCommands ## Generate compile command databases.
    cmdCiTemplate      ## Generate CI templates.
    cmdMetadata        ## Print project metadata.
    cmdGraph           ## Print project graph output.
    cmdQuery           ## Query dependencies.
    cmdTailor          ## Discover target declarations.
    cmdPackage         ## Inspect package contents.
    cmdEnv             ## Print Bau environment details.
    cmdAffected        ## Run affected-work analysis.
    cmdCache           ## Inspect or clean task cache.
    cmdDoctor          ## Check toolchain health.

  CliOptions* = object            ## Parsed command-line options.
    command*: Command             ## Selected command.
    profile*: string              ## Build profile.
    jobs*: int                    ## Parallel build job count.
    verbose*: bool                ## Whether verbose output is enabled.
    quiet*: bool                  ## Whether normal progress output is suppressed.
    help*: bool                   ## Whether command-specific help was requested.
    watch*: bool                  ## Whether to watch files and rerun work.
    color*: string                ## Color mode: `auto`, `always`, or `never`.
    args*: seq[string]            ## Positional command arguments.
    taskName*: string             ## Task or plugin name.
    force*: bool                  ## Force overwrites or bypass cached state.
    timings*: bool                ## Print command timing information.
    open*: bool                   ## Open generated docs when supported.
    dryRun*: bool                 ## Plan without writing when supported.
    keepGoing*: bool              ## Continue independent task deps after failures.
    allTargets*: bool             ## Select all eligible targets.
    changed*: bool                ## Limit work to changed tests where supported.
    json*: bool                   ## Request JSON output.
    list*: bool                   ## Request list output for commands that support it.
    rawCommand*: string           ## Original first CLI token before alias resolution.
    rawArgs*: seq[string]         ## Original command-line arguments.
    aliasResolved*: bool          ## True when this parse came from an alias expansion.
    offline*: bool                ## Avoid network dependency operations.
    locked*: bool                 ## Require an up-to-date lockfile.
    update*: bool                 ## Request update mode for install/deps commands.
    remove*: bool                 ## Request removal mode for install commands.
    write*: bool                  ## Write discovered changes.
    format*: string               ## Output format such as `text`, `json`, or `dot`.
    formatVersion*: int           ## Stable JSON format version.
    features*: seq[string]        ## Requested feature names.
    allFeatures*: bool            ## Enable every feature.
    noDefaultFeatures*: bool      ## Disable the default feature.
    since*: string                ## Git revision or ref for affected analysis.
    precise*: string              ## Exact dependency revision for updates.
    docOutDir*: string            ## Documentation output directory override.
    docEntrypoints*: seq[string]  ## Extra documentation entrypoint files.
    docSkipExamples*: bool        ## Skip runnable examples during docs.
    docIncludePrivate*: bool      ## Include private symbols in docs.
    docNoIndex*: bool             ## Suppress docs index generation.
    testShowOutput*: string       ## Test output mode override.
    installDir*: string           ## Installation directory override.
    passthroughArgs*: seq[string] ## Arguments passed after `--`.
    initInfo*: ProjectInitInfo    ## Project initialization metadata.

proc defaultOptions*(): CliOptions =
  ## Return default CLI options before parsing user arguments.
  let cpus = max(1, countProcessors())
  CliOptions(
    profile: "dev",
    jobs: cpus,
    verbose: false,
    quiet: false,
    watch: false,
    color: "auto",
    timings: false,
    open: false,
    format: "text",
    formatVersion: 1,
    since: "HEAD"
  )

proc parseCliOptions*(params: seq[string] = commandLineParams()): CliOptions =
  ## Parse command-line parameters into `CliOptions`.
  result = defaultOptions()
  result.rawArgs = @params
  if params.len == 0:
    return

  result.rawCommand = params[0]
  result.command = cmdBuild

  var i = 1

  case params[0]
  of "build": result.command = cmdBuild
  of "run": result.command = cmdRun
  of "test": result.command = cmdTest
  of "check": result.command = cmdCheck
  of "doc": result.command = cmdDoc
  of "install": result.command = cmdInstall
  of "update": result.command = cmdUpdate
  of "uninstall": result.command = cmdUninstall
  of "clean": result.command = cmdClean
  of "deps": result.command = cmdDeps
  of "add": result.command = cmdAdd
  of "remove": result.command = cmdRemove
  of "init": result.command = cmdInit
  of "new": result.command = cmdNew
  of "convert": result.command = cmdConvert
  of "version", "--version", "-V": result.command = cmdVersion
  of "help", "--help", "-h": result.command = cmdHelp
  of "task": result.command = cmdTask
  of "fmt", "format": result.command = cmdFmt
  of "lint": result.command = cmdLint
  of "ci": result.command = cmdCi
  of "outdated": result.command = cmdOutdated
  of "tree": result.command = cmdTree
  of "explain": result.command = cmdExplain
  of "publish": result.command = cmdPublish
  of "bump", "version-bump", "bump-version": result.command = cmdBump
  of "shell": result.command = cmdShell
  of "shell-init": result.command = cmdShellInit
  of "compile-commands": result.command = cmdCompileCommands
  of "ci-template": result.command = cmdCiTemplate
  of "metadata": result.command = cmdMetadata
  of "graph": result.command = cmdGraph
  of "query": result.command = cmdQuery
  of "tailor": result.command = cmdTailor
  of "package": result.command = cmdPackage
  of "env": result.command = cmdEnv
  of "affected": result.command = cmdAffected
  of "cache": result.command = cmdCache
  of "doctor": result.command = cmdDoctor
  else:
    let external = findExe("bau-" & params[0])
    if external.len > 0:
      result.command = cmdPlugin
      result.taskName = params[0]
    elif params[0].startsWith("-"):
      result.command = cmdBuild
      i = 0
    else:
      result.command = cmdBuild
      result.args.add(params[0])

  while i < params.len:
    let p = params[i]
    case p
    of "--profile", "-p":
      if i + 1 < params.len:
        result.profile = params[i + 1]
        inc i
    of "--jobs", "-j":
      if i + 1 < params.len:
        result.jobs = parseInt(params[i + 1])
        inc i
    of "--verbose", "-v":
      result.verbose = true
    of "--quiet", "-q":
      result.quiet = true
    of "--help", "-h":
      if result.command == cmdTask:
        result.help = true
      else:
        result.command = cmdHelp
    of "--watch", "-w":
      result.watch = true
    of "--timings":
      result.timings = true
    of "--open":
      result.open = true
    of "--out-dir", "--docs-dir":
      if result.command == cmdDoc and i + 1 < params.len:
        result.docOutDir = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--entry":
      if result.command == cmdDoc and i + 1 < params.len:
        result.docEntrypoints.add(params[i + 1])
        inc i
      else:
        result.args.add(p)
    of "--skip-examples":
      if result.command == cmdDoc:
        result.docSkipExamples = true
      else:
        result.args.add(p)
    of "--include-private":
      if result.command == cmdDoc:
        result.docIncludePrivate = true
      else:
        result.args.add(p)
    of "--no-index":
      if result.command == cmdDoc:
        result.docNoIndex = true
      else:
        result.args.add(p)
    of "--dry-run", "-n":
      result.dryRun = true
    of "--keep-going":
      result.keepGoing = true
    of "--all-targets":
      result.allTargets = true
    of "--changed":
      result.changed = true
    of "--show-output":
      if result.command == cmdTest and i + 1 < params.len:
        result.testShowOutput = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--json":
      result.json = true
      result.format = "json"
    of "--list":
      result.list = true
    of "--offline":
      result.offline = true
    of "--locked":
      result.locked = true
    of "--update":
      if result.command == cmdInstall:
        result.update = true
      else:
        result.args.add(p)
    of "--remove", "--uninstall":
      if result.command == cmdInstall:
        result.remove = true
      else:
        result.args.add(p)
    of "--frozen":
      result.locked = true
      result.offline = true
    of "--write":
      result.write = true
    of "--check":
      if result.command == cmdTailor:
        result.write = false
      else:
        result.args.add(p)
    of "--format":
      if i + 1 < params.len:
        result.format = params[i + 1]
        inc i
    of "--format-version":
      if i + 1 < params.len:
        result.formatVersion = parseInt(params[i + 1])
        inc i
    of "--features":
      if i + 1 < params.len:
        result.features.add(parseFeatureList(params[i + 1]))
        inc i
    of "--all-features":
      result.allFeatures = true
    of "--no-default-features":
      result.noDefaultFeatures = true
    of "--since":
      if i + 1 < params.len:
        result.since = params[i + 1]
        inc i
    of "--precise":
      if i + 1 < params.len:
        result.precise = params[i + 1]
        inc i
    of "--color":
      if i + 1 < params.len:
        result.color = params[i + 1]
        inc i
    of "--install-dir", "--dir":
      if result.command in {cmdInstall, cmdUpdate, cmdUninstall} and
          i + 1 < params.len:
        result.installDir = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--force", "-f":
      result.force = true
    of "--name":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.name = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--kind":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.kind = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--bin":
      if result.command in {cmdInit, cmdNew}:
        result.initInfo.kind = "bin"
      else:
        result.args.add(p)
    of "--lib":
      if result.command in {cmdInit, cmdNew}:
        result.initInfo.kind = "lib"
      else:
        result.args.add(p)
    of "--version":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.version = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--description":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.description = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--license":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.license = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--edition":
      if result.command in {cmdInit, cmdNew} and i + 1 < params.len:
        result.initInfo.edition = params[i + 1]
        inc i
      else:
        result.args.add(p)
    of "--":
      let tail = if i + 1 < params.len: params[(i + 1)..^1] else: @[]
      if result.command == cmdTest:
        result.passthroughArgs = tail
      elif result.command == cmdRun:
        result.passthroughArgs = tail
      elif result.command == cmdTask:
        result.passthroughArgs = tail
      else:
        result.args.add(tail)
      break
    else:
      if result.command == cmdTest and p.startsWith("--show-output="):
        result.testShowOutput = p["--show-output=".len..^1]
      elif result.command == cmdAdd:
        result.args.add(p)
      elif result.command == cmdRemove:
        result.args.add(p)
      elif result.command == cmdNew and result.args.len == 0:
        result.args.add(p)
      elif result.command == cmdConvert and result.args.len == 0:
        result.args.add(p)
      elif result.command == cmdInit:
        if result.initInfo.name.len == 0 and not p.startsWith("-"):
          result.initInfo.name = p
        else:
          result.args.add(p)
      elif result.command == cmdTask and result.taskName.len == 0:
        result.taskName = p
      elif result.command in {cmdDeps, cmdQuery, cmdGraph, cmdTailor,
          cmdPackage, cmdMetadata, cmdEnv, cmdAffected, cmdCache, cmdDoctor,
          cmdInstall, cmdUpdate, cmdUninstall, cmdShellInit}:
        result.args.add(p)
      elif result.command == cmdPlugin:
        result.args.add(p)
      else:
        result.args.add(p)
    inc i

proc printHelp*() =
  ## Print Bau's command-line help text.
  echo """Baumeister (bau) - A modern build tool for Nim

Usage: bau <command> [options]

Commands:
  bau build [target]          Compile the project
  bau run [target] [-- args]  Build and run a binary target
  bau test [filter]           Build and run tests
  bau check                   Type-check without producing binary
  bau doc [--open]            Generate API documentation
  bau install [target]        Build and install a binary target
  bau update [target]         Update an installed binary target
  bau uninstall [target]      Remove an installed binary target
  bau fmt                     Format Nim source files
  bau lint                    Check code style
  bau ci                      Run fmt + lint + test
  bau deps [update]           Sync or update dependencies
  bau deps lock               Write v2 resolved-graph bau.lock
  bau deps sync --locked      Sync only if bau.lock is current
  bau deps update <dep> --precise <rev>
                              Update one materialized git dependency exactly
  bau deps vendor             Copy deps/ to vendor/ with checksums
  bau outdated                Show outdated dependencies
  bau tree                    Show dependency tree
  bau explain                 Show what changed since last build
  bau metadata --json         Print machine-readable project metadata
  bau graph --format dot|json Print task/target/dependency graph
  bau query deps <target>     List dependencies for a target/task
  bau query why <dep>         Explain why a dependency is present
  bau affected [list|build|test|check]
                              Run or list work affected by Git changes
  bau add <dep>               Add a dependency
  bau remove <dep>            Remove a dependency
  bau cache [list|clean|explain]
                              Inspect or clean task output cache
  bau package --list          List files included in a package
  bau bump --patch            Increment [package].version
  bau tailor --check|--write  Discover missing target declarations
  bau doctor                  Check configured toolchain and project health
  bau publish                 Publish to nimble registry
  bau clean                   Remove build artifacts
  bau init [name] [options]   Initialize in current directory
  bau new <path> [--lib]      Create a new project
  bau convert [path|file]     Convert an existing .nimble project to bau.toml
  bau task [--list|<name>]    List or run custom tasks
  bau shell                   Open a shell with build environment
  bau shell-init [shell]      Add ~/.bau/bin to shell startup files
  bau env --json              Print build environment
  bau compile-commands         Generate compile_commands.json for LSP
  bau version                 Print version
  bau help                    Show this help

Options:
  --profile, -p <name>   Build profile: dev | release | test (default: dev)
  --jobs, -j <n>         Parallel build jobs (default: CPU count)
  --verbose, -v          Verbose output
  --quiet, -q            Minimal output
  --watch, -w            Watch for changes and rebuild
  --timings              Show build timing information
  --color <mode>         auto | always | never
  --force, -f            Force overwrite where supported
  --dry-run, -n          Show what would happen without executing
  --keep-going           Continue independent task deps after failures
  --all-targets          Operate on all configured targets where supported
  --changed              Run only changed test files
  --show-output <mode>   Test output: auto | always | never
  --json                 Print JSON where supported
  --format <mode>        Output format, e.g. dot | json
  --format-version <n>   Stable JSON schema version where supported
  --features <a,b>       Enable feature flags from [features]
  --all-features         Enable every declared feature
  --no-default-features  Disable the default feature
  --since <git-ref>      Git ref/range for affected queries (default: HEAD)
  --locked               Require an up-to-date bau.lock
  --offline              Avoid dependency network operations
  --frozen               Equivalent to --locked --offline
  --precise <version>    Exact revision/version for deps update <dep>
  --install-dir <dir>    Override [install].dir for install/update/uninstall
  --update               Update instead of install for bau install
  --remove               Remove instead of install for bau install
  --list                 List package files
  --write                Write discovered tailor changes
  --open                 Open docs in browser (for doc command)
  --out-dir <dir>        Override documentation output directory
  --entry <file>         Add a documentation entrypoint
  --skip-examples        Skip runnableExamples while generating docs
  --include-private      Include non-exported symbols in generated docs
  --no-index             Do not generate Nimdoc search/index files

Init options:
  --name <name>          Project/package name
  --bin | --lib          Project kind
  --version <version>    Initial package version
  --description <text>   Package description
  --license <license>    Package license
  --edition <edition>    Nim edition value

Plugins:
  bau-* commands on PATH are discovered as bau subcommands.
"""

proc printVersion*() =
  ## Print Bau's version string.
  echo "Baumeister (bau) v" & BauVersion

proc selectedFeatures(opts: CliOptions; cfg: BauConfig): FeatureSelection =
  resolveFeatures(cfg, opts.features, opts.allFeatures, opts.noDefaultFeatures)

proc toOperationOptions(opts: CliOptions): OperationOptions =
  result = defaultOperationOptions()
  result.profile = opts.profile
  result.features = opts.features
  result.allFeatures = opts.allFeatures
  result.noDefaultFeatures = opts.noDefaultFeatures
  result.since = opts.since
  result.precise = opts.precise
  result.verbose = opts.verbose
  result.allTargets = opts.allTargets
  result.force = opts.force
  result.dryRun = opts.dryRun
  result.formatVersion = opts.formatVersion
  result.installDir = opts.installDir
  result.docOutDir = opts.docOutDir
  result.docEntrypoints = opts.docEntrypoints
  result.docSkipExamples = opts.docSkipExamples
  result.docIncludePrivate = opts.docIncludePrivate
  result.docNoIndex = opts.docNoIndex

proc requireDependencyValue(args: openArray[string]; i: int;
    option: string): string =
  if i + 1 >= args.len or args[i + 1].startsWith("--"):
    raise newException(ValueError, option & " requires a value")
  args[i + 1]

proc applyDependencyArgs*(opOpts: var OperationOptions;
    args: openArray[string]) =
  ## Parse dependency-specific CLI flags into operation options.
  var i = 0
  while i < args.len:
    case args[i]
    of "--git":
      opOpts.depGit = requireDependencyValue(args, i, "--git")
      inc i
    of "--tag":
      opOpts.depTag = requireDependencyValue(args, i, "--tag")
      inc i
    of "--branch":
      opOpts.depBranch = requireDependencyValue(args, i, "--branch")
      inc i
    of "--rev":
      opOpts.depRev = requireDependencyValue(args, i, "--rev")
      inc i
    of "--path":
      opOpts.depPath = requireDependencyValue(args, i, "--path")
      inc i
    of "--registry":
      opOpts.depRegistry = requireDependencyValue(args, i, "--registry")
      inc i
    of "--version":
      opOpts.depVersion = requireDependencyValue(args, i, "--version")
      inc i
    of "--optional":
      opOpts.depOptional = true
    else:
      raise newException(ValueError, "unknown dependency option: " & args[i])
    inc i

  if opOpts.depGit.len > 0 and opOpts.depPath.len > 0:
    raise newException(ValueError, "dependency cannot use both --git and --path")
  if opOpts.depPath.len > 0 and (opOpts.depTag.len > 0 or
      opOpts.depBranch.len > 0 or opOpts.depRev.len > 0):
    raise newException(ValueError,
      "--tag, --branch, and --rev require --git, not --path")
  if opOpts.depGit.len == 0 and (opOpts.depTag.len > 0 or
      opOpts.depBranch.len > 0 or opOpts.depRev.len > 0):
    raise newException(ValueError, "--tag, --branch, and --rev require --git")

proc printTaskCommandHelp*() =
  ## Print help for the task command.
  echo """Usage:
  bau task --list
  bau task <name> [-- args...]
  bau task <name> --help

Options:
  --list          List configured tasks
  --dry-run, -n   Show planned task work
  --keep-going    Continue independent task deps after failures
  --force, -f     Bypass task freshness and cache hits

Task args:
  Tasks only accept args when acceptArgs = true is set in bau.toml.
  Args are available as {args}, BAU_TASK_ARGS, and BAU_TASK_ARG_0, ...
"""

proc findTask(cfg: BauConfig; name: string): Option[TaskInfo] =
  for task in cfg.tasks:
    if task.name == name:
      return some(task)
  result = none(TaskInfo)

proc taskCacheable(task: TaskInfo): bool =
  task.cache or (task.inputs.len > 0 and task.outputs.len > 0)

proc printTaskList*(cfg: BauConfig) =
  ## Print configured tasks with descriptions and useful flags.
  if cfg.tasks.len == 0:
    echo "no tasks configured"
    return
  echo "tasks:"
  for task in cfg.tasks:
    var line = "  " & task.name
    if task.description.len > 0:
      line.add(" - " & task.description)
    var details: seq[string]
    if task.deps.len > 0:
      details.add("deps: " & task.deps.join(", "))
    if taskCacheable(task):
      details.add("cacheable")
    if task.acceptArgs:
      details.add("args")
    if task.command.len > 0:
      details.add("command: " & task.command)
    if details.len > 0:
      line.add(" [" & details.join("; ") & "]")
    echo line

proc printTaskDetails*(cfg: BauConfig; projectDir: string; opts: CliOptions) =
  ## Print metadata for one configured task.
  let taskOpt = findTask(cfg, opts.taskName)
  if taskOpt.isNone:
    error("task not found: " & opts.taskName)
    quit(1)
  let task = taskOpt.get()
  echo "task: " & task.name
  if task.description.len > 0:
    echo "description: " & task.description
  if task.cmd.len > 0:
    echo "cmd: " & task.cmd
  if task.command.len > 0:
    echo "command: " & task.command
  if task.profile.len > 0:
    echo "profile: " & task.profile
  if task.deps.len > 0:
    echo "deps: " & task.deps.join(", ")
  if task.inputs.len > 0:
    echo "inputs: " & task.inputs.join(", ")
  if task.outputs.len > 0:
    echo "outputs: " & task.outputs.join(", ")
  if task.cwd.isSome:
    echo "cwd: " & task.cwd.get()
  if task.shell.len > 0:
    echo "shell: " & task.shell
  if task.requiredFeatures.len > 0:
    echo "requiredFeatures: " & task.requiredFeatures.join(", ")
  if task.tags.len > 0:
    echo "tags: " & task.tags.join(", ")
  echo "acceptArgs: " & $task.acceptArgs
  echo "cacheable: " & $taskCacheable(task)
  if taskCacheable(task):
    let entry = taskCacheEntry(task, projectDir, cfg, opts.profile,
      selectedFeatures(opts, cfg))
    echo "cacheKey: " & entry.key
    echo "localCache: " & (if cacheEntryExists(entry): "hit" else: "miss")

proc fmtSources*(projectDir: string; verbose: bool = false) =
  ## Format Nim files under a project's `src` directory with `nimpretty`.
  let nimpretty = findExe("nimpretty")
  if nimpretty.len == 0:
    error("nimpretty not found — install nimble to get it")
    quit(1)
  let sourceDir = projectDir / "src"
  if not dirExists(sourceDir):
    warn("no src/ directory found")
    return
  info("formatting sources with nimpretty...")
  for f in walkDirRec(sourceDir, yieldFilter = {pcFile}):
    if not f.endsWith(".nim"):
      continue
    if verbose:
      echo "  " & f
    runCmdLive(nimpretty, ["--backup:off", f])

proc fmtCommand*(opts: CliOptions) =
  ## Execute the `fmt` command.
  let projectDir = findProjectRoot()
  fmtSources(projectDir)
  success("fmt  done")

proc lintCommand*(opts: CliOptions) =
  ## Execute the `lint` command.
  let projectDir = findProjectRoot()
  let cfg = parseBauConfigFile(projectDir / ConfigFileName)
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let absSource = absolutePath(projectDir) / sourceDir
  var issues = 0
  if dirExists(absSource):
    info("checking style of Nim sources...")
    var lintArgs = @["check", "--styleCheck:error", "--hints:off", "--path:" & absSource]
    let depsDir = projectDir / "deps"
    if dirExists(depsDir):
      for kind, path in walkDir(depsDir):
        if kind == pcDir:
          lintArgs.add("--path:" & path)
    for f in walkDirRec(absSource, yieldFilter = {pcFile}):
      if not f.endsWith(".nim"):
        continue
      var fileArgs = lintArgs
      fileArgs.add(f)
      let (exitCode, output) = runCmd(detectNimCompiler(), fileArgs)
      if exitCode != 0:
        issues += 1
        error(f & " has style issues")
        if output.len > 0:
          echo output
      else:
        if opts.verbose:
          success("style ok: " & f.extractFilename)
  if issues > 0:
    error($issues & " file(s) with style issues")
    quit(1)
  success("lint OK")

proc ciCommand*(opts: CliOptions) =
  ## Execute Bau's local CI sequence.
  info("===> CI: fmt")
  fmtCommand(opts)
  info("===> CI: lint")
  lintCommand(opts)
  info("===> CI: test")
  let projectDir = findProjectRoot()
  let cfg = loadEffectiveConfig(projectDir)
  if not dirExists(projectDir / "tests") and cfg.test.runner.len == 0:
    warn("no tests directory found")
    return
  let testResult = runTests(cfg, projectDir, TestRunOptions(
    profile: opts.profile,
    since: opts.since,
    showOutput: effectiveTestOutputMode(cfg, opts.testShowOutput),
    verbose: opts.verbose,
    featureSelection: selectedFeatures(opts, cfg)))
  echo ""
  info("test results: " & $testResult.passed & " passed, " &
    $testResult.failed & " failed")
  if testResult.failed > 0:
    quit(1)
  success("CI passed")

proc toLockProjects(projects: openArray[WorkspaceProject]): seq[LockProject] =
  for project in projects:
    result.add(LockProject(path: project.path, projectDir: project.projectDir,
      cfg: project.cfg))

proc reportDependencyCheck(check: DependencyCheck; prefix = "") =
  for msg in check.messages:
    if check.ok:
      info(prefix & msg)
    else:
      error(prefix & msg)

proc unresolvedForProjects(projects: openArray[WorkspaceProject];
    lockFile: LockFile): seq[string] =
  for project in projects:
    for name in unresolvedLockEntries(project.cfg, lockFile,
        project.projectDir):
      result.add(project.path & ":" & name)
  result.sort()

proc checkoutPreciseDependency(projectDir, depName, precise: string) =
  if precise.len == 0:
    return
  if depName.len == 0:
    error("deps update --precise requires a package name")
    quit(1)
  let depPath = projectDir / "deps" / depName
  if not dirExists(depPath / ".git"):
    error("deps update --precise currently requires a materialized git dependency: " &
      depName)
    quit(1)
  runCmdLive("git", ["-C", depPath, "checkout", precise])

proc vendorDependencies(projectDir: string) =
  let depsDir = projectDir / "deps"
  if not dirExists(depsDir):
    error("no deps/ directory found; run bau deps sync first")
    quit(1)
  let vendorDir = projectDir / "vendor"
  if dirExists(vendorDir):
    removeDir(vendorDir)
  copyDir(depsDir, vendorDir)
  var manifest = "# bau vendor checksums\n"
  for kind, path in walkDir(vendorDir):
    if kind == pcDir:
      let name = path.extractFilename
      manifest.add(name & " = " & toTomlString(checksumPath(path)) & "\n")
  saveFile(vendorDir / ".bau-vendor-checksums", manifest)

proc depsCommand*(opts: CliOptions) =
  ## Execute dependency subcommands such as sync, update, lock, and verify.
  let projectDir = findProjectRoot()
  let subcmd = if opts.args.len > 0: opts.args[0] else: "sync"
  if isWorkspaceRoot(projectDir) and subcmd in ["lock", "sync", "update",
      "verify", "vendor"]:
    let projects = loadWorkspaceProjects(projectDir)
    let lockProjects = toLockProjects(projects)
    let lockPath = projectDir / LockFileName
    if opts.locked:
      let report = validateLockFile(lockProjects, projectDir, lockPath)
      if not report.ok:
        for msg in report.messages:
          error(msg)
        quit(1)
    case subcmd
    of "lock":
      let lockFile = generateLockFile(lockProjects, projectDir)
      let unresolved = unresolvedForProjects(projects, lockFile)
      if unresolved.len > 0:
        error("cannot write reproducible " & LockFileName &
          "; dependency material is missing for " & unresolved.join(", ") &
          " (run deps sync first)")
        quit(1)
      writeLockFile(lockFile, lockPath)
      success("wrote workspace " & LockFileName)
    of "sync":
      var selections: seq[FeatureSelection]
      for project in projects:
        selections.add(selectedFeatures(opts, project.cfg))
      if opts.offline:
        let check = checkOfflineDependencies(lockProjects, projectDir, lockPath,
          selections)
        reportDependencyCheck(check)
        if not check.ok:
          quit(1)
        success("workspace dependencies available offline")
      else:
        for i, project in projects:
          info(project.path & ": syncing dependencies with atlas...")
          syncDeps(project.cfg, project.projectDir, verbose = opts.verbose,
            featureSelection = selections[i])
        let lockFile = generateLockFile(lockProjects, projectDir)
        let unresolved = unresolvedForProjects(projects, lockFile)
        if unresolved.len > 0:
          error("dependency material missing after sync: " &
            unresolved.join(", "))
          quit(1)
        writeLockFile(lockFile, lockPath)
    of "update":
      if opts.offline:
        error("deps update cannot run with --offline")
        quit(1)
      let filter = if opts.args.len > 1: opts.args[1] else: ""
      for project in projects:
        info(project.path & ": updating dependencies with atlas...")
        updateDeps(project.projectDir, filter, verbose = opts.verbose)
        checkoutPreciseDependency(project.projectDir, filter, opts.precise)
      let refreshedProjects = loadWorkspaceProjects(projectDir)
      let refreshedLockProjects = toLockProjects(refreshedProjects)
      let lockFile = generateLockFile(refreshedLockProjects, projectDir)
      let unresolved = unresolvedForProjects(refreshedProjects, lockFile)
      if unresolved.len > 0:
        error("dependency material missing after update: " &
          unresolved.join(", "))
        quit(1)
      writeLockFile(lockFile, lockPath)
    of "verify":
      let check = checkDependencyPolicy(lockProjects, projectDir, lockPath)
      reportDependencyCheck(check)
      if not check.ok:
        quit(1)
      success("workspace dependencies verified")
    of "vendor":
      for project in projects:
        vendorDependencies(project.projectDir)
      success("vendored workspace dependencies")
    else:
      discard
    return

  let cfg = loadEffectiveConfig(projectDir)
  let featureSelection = selectedFeatures(opts, cfg)
  let lockPath = projectDir / LockFileName

  if opts.locked:
    let report = validateLockFile(cfg, projectDir, lockPath)
    if not report.ok:
      for msg in report.messages:
        error(msg)
      quit(1)

  case subcmd
  of "lock":
    let lockFile = generateLockFile(cfg, projectDir)
    let unresolved = unresolvedLockEntries(cfg, lockFile, projectDir)
    if unresolved.len > 0:
      error("cannot write reproducible " & LockFileName &
        "; dependency material is missing for " & unresolved.join(", ") &
        " (run deps sync first)")
      quit(1)
    writeLockFile(lockFile, lockPath)
    success("wrote " & LockFileName)
  of "sync":
    if opts.offline:
      let check = checkOfflineDependencies(cfg, projectDir, featureSelection)
      for msg in check.messages:
        if check.ok:
          info(msg)
        else:
          error(msg)
      if not check.ok:
        quit(1)
      success("dependencies available offline")
    else:
      info("syncing dependencies with atlas...")
      syncDeps(cfg, projectDir, verbose = opts.verbose,
        featureSelection = featureSelection)
      let lockFile = generateLockFile(cfg, projectDir)
      let unresolved = unresolvedLockEntries(cfg, lockFile, projectDir)
      if unresolved.len > 0:
        error("dependency material missing after sync: " & unresolved.join(", "))
        quit(1)
      writeLockFile(lockFile, lockPath)
  of "update":
    if opts.offline:
      error("deps update cannot run with --offline")
      quit(1)
    let filter = if opts.args.len > 1: opts.args[1] else: ""
    info("updating dependencies with atlas...")
    updateDeps(projectDir, filter, verbose = opts.verbose)
    checkoutPreciseDependency(projectDir, filter, opts.precise)
    let refreshed = loadEffectiveConfig(projectDir)
    let lockFile = generateLockFile(refreshed, projectDir)
    let unresolved = unresolvedLockEntries(refreshed, lockFile, projectDir)
    if unresolved.len > 0:
      error("dependency material missing after update: " & unresolved.join(", "))
      quit(1)
    writeLockFile(lockFile, lockPath)
  of "vendor":
    vendorDependencies(projectDir)
    success("vendored dependencies to vendor/")
  of "verify":
    let check = checkDependencyPolicy(cfg, projectDir)
    reportDependencyCheck(check)
    if not check.ok:
      quit(1)
    success("dependencies verified")
  of "patch":
    if opts.args.len < 3 or opts.args[2] != "--path":
      error("usage: bau deps patch <dep> --path <path>")
      quit(1)
    if opts.args.len < 4:
      error("bau deps patch requires a path")
      quit(1)
    writePatchEntry(projectDir, opts.args[1], opts.args[3])
    success("patched dependency '" & opts.args[1] & "'")
  else:
    error("unknown deps command: " & subcmd)
    quit(1)

proc metadataCommand*(opts: CliOptions) =
  ## Execute the `metadata` command.
  let projectDir = findProjectRoot()
  let op = metadataOperation(projectDir, opts.toOperationOptions())
  if opts.json or opts.format == "json":
    echo pretty(op.json)
  else:
    if op.json{"workspace"}.getBool(false):
      echo "workspace: " & op.json["root"].getStr()
      echo "members: " & $op.json["members"].len
    else:
      let cfg = loadEffectiveConfig(projectDir)
      echo cfg.package.name & " " & cfg.package.version
      echo "targets: " & $(cfg.targets.len + 1)
      echo "dependencies: " & $cfg.deps.len
      echo "tasks: " & $cfg.tasks.len

proc graphCommand*(opts: CliOptions) =
  ## Execute the `graph` command.
  let projectDir = findProjectRoot()
  let op = graphOperation(projectDir, opts.toOperationOptions())
  if opts.format == "json":
    echo pretty(op.json)
  else:
    if op.json{"workspace"}.getBool(false):
      echo pretty(op.json)
    else:
      echo graphDot(loadEffectiveConfig(projectDir), projectDir)

proc queryCommand*(opts: CliOptions) =
  ## Execute dependency query commands.
  let projectDir = findProjectRoot()
  if opts.args.len < 1:
    error("query requires 'deps <target>' or 'why <dependency>'")
    quit(1)
  var opOpts = opts.toOperationOptions()
  opOpts.queryKind = opts.args[0]
  case opts.args[0]
  of "deps":
    opOpts.queryName = if opts.args.len > 1: opts.args[1] else: ""
    let op = queryOperation(projectDir, opOpts)
    if opts.json or opts.format == "json":
      echo pretty(op.json)
    else:
      if op.json.kind == JArray:
        for dep in op.json.getElems:
          echo dep.getStr()
      else:
        echo pretty(op.json)
  of "why":
    if opts.args.len < 2:
      error("query why requires a dependency name")
      quit(1)
    opOpts.queryName = opts.args[1]
    let op = queryOperation(projectDir, opOpts)
    if opts.json or opts.format == "json":
      echo pretty(op.json)
    elif op.json.hasKey("why"):
      echo op.json["why"].getStr()
    else:
      echo pretty(op.json)
  else:
    error("unknown query: " & opts.args[0])
    quit(1)

proc packageCommand*(opts: CliOptions) =
  ## Execute package inspection and manifest generation.
  let projectDir = findProjectRoot()
  let cfg = loadEffectiveConfig(projectDir)
  verifyPackage(projectDir, cfg)
  let files = collectPackageFiles(projectDir, cfg)
  if opts.list or opts.dryRun:
    for f in files:
      echo f
  if opts.dryRun:
    success("package dry-run OK")
  elif not opts.list:
    let outDir = projectDir / BuildDirName / "package"
    let manifestPath = outDir / (cfg.package.name & "-" & cfg.package.version &
      ".manifest")
    saveFile(manifestPath, packageManifest(projectDir, cfg))
    success("wrote package manifest " & manifestPath)

proc installActionForCommand(opts: CliOptions): string =
  case opts.command
  of cmdInstall:
    if opts.update and opts.remove:
      raise newException(ValueError,
        "bau install cannot use both --update and --remove")
    if opts.update:
      "update"
    elif opts.remove:
      "remove"
    else:
      "install"
  of cmdUpdate:
    "update"
  of cmdUninstall:
    "remove"
  else:
    "install"

proc printInstallResult(node: JsonNode) =
  let action = node["action"].getStr()
  let target = node["target"].getStr()
  let destination = node["destination"].getStr()
  if node["dryRun"].getBool():
    info("would " & action & " " & target & " -> " & destination)
    return
  if action == "remove":
    if node["changed"].getBool():
      success("removed " & target & " from " & destination)
    else:
      info("not installed: " & destination)
  elif action == "update":
    success("updated " & target & " -> " & destination)
  else:
    success("installed " & target & " -> " & destination)

proc installCommand*(opts: CliOptions) =
  ## Execute install, update, and uninstall commands.
  let projectDir = findProjectRoot()
  var opOpts = opts.toOperationOptions()
  try:
    opOpts.installAction = installActionForCommand(opts)
  except ValueError as e:
    error(e.msg)
    quit(1)
  if opts.args.len > 0:
    opOpts.targetName = opts.args[0]
  if opts.args.len > 1:
    error("install accepts at most one target name")
    quit(1)
  if opts.allTargets and opOpts.targetName.len > 0:
    error("install cannot combine a target name with --all-targets")
    quit(1)

  let op = installOperation(projectDir, opOpts)
  if opts.json or opts.format == "json":
    echo pretty(op.json)
  else:
    if op.ok:
      for item in op.json["targets"].getElems():
        printInstallResult(item)
    else:
      error(op.json{"error"}.getStr(op.output))
  if not op.ok:
    quit(1)

proc tailorCommand*(opts: CliOptions) =
  ## Execute target-discovery and config-tailoring commands.
  let projectDir = findProjectRoot()
  if isWorkspaceRoot(projectDir):
    var members = newJArray()
    var reports: seq[string]
    var missing = 0
    for project in loadWorkspaceProjects(projectDir):
      let tailored = discoverTargets(project.cfg, project.projectDir)
      missing += tailored.missingTargets.len
      reports.add(project.path & ":\n" & tailorReport(tailored))
      members.add(%*{
        "path": project.path,
        "name": project.name,
        "tailor": tailorJson(tailored)
      })
      if opts.write:
        appendTailoredTargets(project.projectDir, tailored)
    let node = %*{
      "workspace": true,
      "root": projectDir,
      "members": members,
      "ok": missing == 0
    }
    if opts.json or opts.format == "json":
      echo pretty(node)
    else:
      for report in reports:
        echo report
    if opts.write and missing > 0:
      success("updated workspace member target declarations")
    elif missing > 0:
      quit(1)
    return

  let cfg = loadEffectiveConfig(projectDir)
  let tailored = discoverTargets(cfg, projectDir)
  if opts.json or opts.format == "json":
    echo pretty(tailorJson(tailored))
  else:
    echo tailorReport(tailored)
  if opts.write:
    appendTailoredTargets(projectDir, tailored)
    if tailored.missingTargets.len > 0:
      success("updated " & ConfigFileName)
  elif tailored.missingTargets.len > 0:
    quit(1)

proc envCommand*(opts: CliOptions) =
  ## Execute the environment-reporting command.
  let projectDir = try: findProjectRoot() except: getCurrentDir()
  let cfg = try: loadEffectiveConfig(projectDir) except: initBauConfig()
  let featureSelection = selectedFeatures(opts, cfg)
  let node = %*{
    "projectDir": projectDir,
    "profile": opts.profile,
    "features": featureSelection.enabled,
    "nim": detectNimCompiler(),
    "atlas": (try: detectAtlas() except CatchableError: ""),
    "declared": {
      "nim": cfg.toolchain.nim,
      "atlas": cfg.toolchain.atlas
    }
  }
  if opts.json or opts.format == "json":
    echo pretty(node)
  else:
    echo "BAU_PROJECT_DIR=" & projectDir
    echo "BAU_PROFILE=" & opts.profile
    for name in featureSelection.enabled:
      echo "BAU_FEATURE_" & normalizeFeatureDefine(name).toUpperAscii() & "=1"
    echo "NIM=" & node["nim"].getStr()
    if node["atlas"].getStr().len > 0:
      echo "ATLAS=" & node["atlas"].getStr()

proc affectedCommand*(opts: CliOptions) =
  ## Execute affected-work commands.
  let projectDir = findProjectRoot()
  let cfg = loadEffectiveConfig(projectDir)
  let featureSelection = selectedFeatures(opts, cfg)
  let report = computeAffected(cfg, projectDir, opts.since)
  let action = if opts.args.len > 0: opts.args[0] else: "list"
  case action
  of "list":
    let op = affectedOperation(projectDir, opts.toOperationOptions())
    if opts.json or opts.format == "json":
      echo pretty(op.json)
    elif op.json{"workspace"}.getBool(false):
      echo pretty(op.json)
    else:
      echo "changed:"
      for file in report.changedFiles:
        echo "  " & file
      echo "targets:"
      for target in report.targets:
        echo "  " & target
      echo "tests:"
      for test in report.tests:
        echo "  " & test
      echo "tasks:"
      for task in report.tasks:
        echo "  " & task
  of "build":
    for target in report.targets:
      discard buildTargetByName(cfg, target, opts.profile, projectDir,
        opts.verbose, featureSelection)
  of "test":
    let profName = if cfg.profiles.hasKey("test"): "test" else: opts.profile
    let prof = if cfg.profiles.hasKey(profName):
                 resolveProfile(cfg.profiles, profName)
               else:
                 initProfileInfo()
    let outDir = absolutePath(projectDir) / BuildDirName / profName
    let flags = collectCompilerFlags(prof, bkTest, outDir, cfg.build.source,
      projectDir, cfg, featureSelection)
    for testFile in report.tests:
      var args = @["c", "-r"]
      args.add(flags)
      args.add(testFile)
      runCmdLive(detectNimCompiler(), args, projectDir)
  of "check":
    let prof = if cfg.profiles.hasKey(opts.profile):
                 resolveProfile(cfg.profiles, opts.profile)
               else:
                 initProfileInfo()
    let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
    let outDir = absolutePath(projectDir) / BuildDirName / opts.profile
    let flags = collectCompilerFlags(prof, cfg.build.kind, outDir, sourceDir,
      projectDir, cfg, featureSelection)
    for target in report.targets:
      let idx = findTargetIndex(cfg, target)
      let mainFile = if idx >= 0: cfg.targets[idx].main else: cfg.build.main
      var args = @["check"]
      args.add(flags)
      args.add(mainFile)
      runCmdLive(detectNimCompiler(), args, projectDir)
  else:
    error("unknown affected action: " & action)
    quit(1)

proc cacheCommand*(opts: CliOptions) =
  ## Execute task-cache inspection and cleanup commands.
  let projectDir = findProjectRoot()
  let cfg = loadEffectiveConfig(projectDir)
  let action = if opts.args.len > 0: opts.args[0] else: "list"
  case action
  of "list":
    let entries = listTaskCacheEntries(projectDir, cfg)
    if opts.json or opts.format == "json":
      echo pretty(%entries)
    else:
      for entry in entries:
        echo entry
  of "clean":
    cleanTaskCache(projectDir, cfg)
    success("task cache cleaned")
  of "explain":
    if opts.args.len < 2:
      error("usage: bau cache explain <task>")
      quit(1)
    var opOpts = opts.toOperationOptions()
    opOpts.taskName = opts.args[1]
    let op = cacheExplainOperation(projectDir, opOpts)
    if not op.ok:
      error("task not found: " & opts.args[1])
      quit(1)
    if opts.json or opts.format == "json" or op.json{"workspace"}.getBool(false):
      echo pretty(op.json)
    else:
      echo "task: " & op.json["task"].getStr()
      echo "key: " & op.json["key"].getStr()
      echo "path: " & op.json["path"].getStr()
      echo "local hit: " & $op.json["localHit"].getBool()
      echo "remote hit: " & $op.json["remoteHit"].getBool()
      if op.json["remoteError"].getStr().len > 0:
        echo "remote error: " & op.json["remoteError"].getStr()
      echo "outputs:"
      for output in op.json["outputs"].getElems():
        echo "  " & output.getStr()
  else:
    error("unknown cache action: " & action)
    quit(1)

proc doctorCommand*(opts: CliOptions) =
  ## Execute toolchain and project health checks.
  let projectDir = try: findProjectRoot() except: getCurrentDir()
  let cfg = try: loadEffectiveConfig(projectDir) except: initBauConfig()
  let check = checkToolchain(cfg)
  for msg in check.messages:
    if check.ok:
      info(msg)
    else:
      error(msg)
  if not check.ok:
    quit(1)
  success("doctor OK")

proc outdatedCommand*(opts: CliOptions) =
  ## Execute dependency status reporting.
  let projectDir = findProjectRoot()
  if isWorkspaceRoot(projectDir):
    let projects = loadWorkspaceProjects(projectDir)
    if opts.json or opts.format == "json":
      var members = newJArray()
      for project in projects:
        members.add(%*{
          "path": project.path,
          "name": project.name,
          "status": dependencyStatusJson(project.cfg, project.projectDir)
        })
      echo pretty(%*{"workspace": true, "root": projectDir,
        "kind": "dependencyStatus", "members": members})
    else:
      for project in projects:
        echo project.path & ":"
        stdout.write(dependencyStatusText(project.cfg, project.projectDir))
    return

  let cfg = loadEffectiveConfig(projectDir)
  if opts.json or opts.format == "json":
    echo pretty(dependencyStatusJson(cfg, projectDir))
    return

  stdout.write(dependencyStatusText(cfg, projectDir))
  if atlasInitialized(projectDir):
    info("checking outdated dependencies...")
    let (exitCode, output) = runAtlas(["outdated"], projectDir, opts.verbose)
    if output.strip().len > 0:
      echo output
    if exitCode == 0 and output.strip().len == 0:
      success("all dependencies up to date")
    elif exitCode != 0:
      quit(exitCode)

proc treeCommand*(opts: CliOptions) =
  ## Execute dependency tree reporting.
  let projectDir = findProjectRoot()
  if isWorkspaceRoot(projectDir):
    let projects = loadWorkspaceProjects(projectDir)
    if opts.json or opts.format == "json":
      var members = newJArray()
      for project in projects:
        members.add(%*{
          "path": project.path,
          "name": project.name,
          "tree": dependencyTreeJson(project.cfg, project.projectDir)
        })
      echo pretty(%*{"workspace": true, "root": projectDir,
        "kind": "dependencyTree", "members": members})
    else:
      for project in projects:
        echo project.path & ":"
        stdout.write(dependencyTreeText(project.cfg, project.projectDir))
    return

  let cfg = loadEffectiveConfig(projectDir)
  if opts.json or opts.format == "json":
    echo pretty(dependencyTreeJson(cfg, projectDir))
  else:
    stdout.write(dependencyTreeText(cfg, projectDir))

proc printCompareLine(comparison: JsonNode; key, label: string) =
  let unchanged = comparison[key]["unchanged"].getBool()
  echo "    " & label & ": " & (if unchanged: "unchanged" else: "CHANGED")

proc printExplainText(node: JsonNode) =
  if node{"workspace"}.getBool(false):
    echo pretty(node)
    return

  info("build cache info for: " & node["target"].getStr() & " (" &
    node["profile"].getStr() & ")")
  if not node["cached"].getBool():
    error(node{"message"}.getStr("no cached fingerprint"))
    return

  echo "  fingerprint comparison:"
  let comparison = node["comparison"]
  comparison.printCompareLine("source", "source")
  comparison.printCompareLine("flags", "flags")
  comparison.printCompareLine("config", "config")
  comparison.printCompareLine("env", "env")
  comparison.printCompareLine("compiler", "compiler")
  comparison.printCompareLine("profile", "profile")
  comparison.printCompareLine("mtime", "mtime")

  if node["wouldSkip"].getBool():
    success("no changes since last build — rebuild would be skipped")
  else:
    if not node["outputExists"].getBool():
      echo "  output missing: " & node["binary"].getStr()
    if node.hasKey("changedFilesNewerThanOutput") and
        node["changedFilesNewerThanOutput"].len > 0:
      echo "  changed files newer than output:"
      for file in node["changedFilesNewerThanOutput"].getElems():
        echo "    " & file.getStr()

proc explainCommand*(opts: CliOptions) =
  ## Execute build-cache explanation output.
  let projectDir = findProjectRoot()
  let op = explainOperation(projectDir, opts.toOperationOptions())
  if opts.json or opts.format == "json":
    echo pretty(op.json)
  else:
    printExplainText(op.json)
    if not op.json{"workspace"}.getBool(false) and
        not op.json["cached"].getBool():
      quit(1)

proc publishCommand*(opts: CliOptions) =
  ## Execute package publishing or publish dry-run inspection.
  let projectDir = findProjectRoot()
  if not fileExists(projectDir / ConfigFileName):
    error("no bau.toml found")
    quit(1)
  let cfg = parseBauConfigFile(projectDir / ConfigFileName)
  verifyPackage(projectDir, cfg)
  if hasLocalPublishOverrides(cfg) and not opts.dryRun:
    error("publish cannot use local path dependencies or [patch]; run --dry-run to inspect")
    quit(1)
  if opts.dryRun:
    success("publish dry-run OK")
    for f in collectPackageFiles(projectDir, cfg):
      echo f
    echo ""
    echo nimbleContent(cfg)
    return

  let nimbleCmd = findExe("nimble")
  if nimbleCmd.len == 0:
    error("nimble not found — install it to publish")
    quit(1)
  if not fileExists(projectDir / (cfg.package.name & ".nimble")):
    let nimblePath = projectDir / (cfg.package.name & ".nimble")
    saveFile(nimblePath, nimbleContent(cfg))
    success("generated " & cfg.package.name & ".nimble from bau.toml")
  info("publishing with nimble...")
  runCmdLive(nimbleCmd, ["publish"])

proc bumpCommand*(opts: CliOptions) =
  ## Increment the project package version in Bau metadata.
  if opts.args.len != 1:
    error("usage: bau bump <major|minor|patch> or bau bump --patch")
    quit(1)

  let projectDir = findProjectRoot()
  try:
    let kind = parseVersionBumpKind(opts.args[0])
    let bumped = bumpPackageVersion(projectDir, kind, opts.dryRun)
    let change = bumped.oldVersion & " -> " & bumped.newVersion
    if opts.dryRun:
      echo change
      if bumped.nimblePath.len > 0:
        echo "would update " & relativePath(bumped.nimblePath, projectDir)
    else:
      success("version " & change)
      if bumped.nimbleChanged:
        success("updated " & relativePath(bumped.nimblePath, projectDir))
  except CatchableError as e:
    error(e.msg)
    quit(1)

proc shellCommand*(opts: CliOptions) =
  ## Execute an interactive shell with Bau environment variables set.
  let projectDir = try: findProjectRoot() except: getCurrentDir()
  let cfg = try: loadEffectiveConfig(projectDir) except: initBauConfig()
  let featureSelection = selectedFeatures(opts, cfg)
  echo "Baumeister shell — " & projectDir
  echo "  profile: " & opts.profile
  echo "  type 'exit' to leave"
  putEnv("BAU_PROJECT_DIR", projectDir)
  putEnv("BAU_PROFILE", opts.profile)
  for name in featureSelection.enabled:
    putEnv("BAU_FEATURE_" & normalizeFeatureDefine(name).toUpperAscii(), "1")
  info("build env active")
  var shell = findExe("bash")
  if shell.len == 0:
    shell = findExe("sh")
  runCmdLive(shell, [])

proc shellInitResultNode(item: ShellInitResult): JsonNode =
  %*{
    "shell": item.shell,
    "configPath": item.configPath,
    "binDir": item.binDir,
    "changed": item.changed,
    "alreadyInPath": item.alreadyInPath,
    "alreadyConfigured": item.alreadyConfigured
  }

proc shellInitCommand*(opts: CliOptions) =
  ## Add Bau's binary directory to the selected shell startup file.
  if opts.args.len > 1:
    error("shell-init accepts at most one shell name")
    quit(1)

  let selectedShell = if opts.args.len == 1: opts.args[0] else: ""
  try:
    let result = initShellPath(selectedShell)
    if opts.json or opts.format == "json":
      echo pretty(shellInitResultNode(result))
    elif result.changed:
      success("added " & result.binDir & " to " & result.configPath)
      info("restart your shell or source " & result.configPath)
    elif result.alreadyConfigured:
      success(result.binDir & " is already configured in " &
        result.configPath)
    else:
      success(result.binDir & " is already on PATH")
  except ValueError as e:
    error(e.msg)
    quit(1)

proc pluginCommand*(opts: CliOptions) =
  ## Execute an external `bau-*` plugin command.
  let external = findExe("bau-" & opts.taskName)
  if external.len == 0:
    error("unknown command: " & opts.taskName)
    quit(1)
  info("invoking plugin: bau-" & opts.taskName)
  runCmdLive(external, opts.args)

proc printConvertDiagnostics(diagnostics: openArray[ConvertDiagnostic];
    verbose: bool) =
  for diag in diagnostics:
    let prefix = if diag.line > 0: "line " & $diag.line & ": " else: ""
    case diag.severity
    of csWarning:
      warn(prefix & diag.message)
    of csInfo:
      if verbose:
        info(prefix & diag.message)

proc convertCommand*(opts: CliOptions) =
  ## Execute Nimble-to-Bau conversion.
  var projectDir = getCurrentDir()
  var nimblePath = ""
  if opts.args.len > 0:
    let input = opts.args[0]
    if dirExists(input):
      projectDir = input
    else:
      nimblePath = input
      projectDir = parentDir(absolutePath(input))

  let conversion = convertNimbleProject(projectDir, nimblePath,
    write = not opts.dryRun, force = opts.force)
  if opts.json or opts.format == "json":
    echo pretty(convertResultJson(conversion))
  else:
    if opts.dryRun:
      echo conversion.content
    printConvertDiagnostics(conversion.diagnostics, opts.verbose)
    if conversion.wrote:
      success("converted " & conversion.nimblePath & " -> " &
        conversion.configPath)
    else:
      success("conversion dry-run OK for " & conversion.nimblePath)

proc printDocSummary(node: JsonNode; prefix = "") =
  if node.hasKey("error"):
    error(prefix & node["error"].getStr())
    return
  let moduleCount = node["modules"].len
  success(prefix & "docs    generated " & $moduleCount & " module(s) at " &
    node["outDir"].getStr())
  if node.hasKey("diagnostics") and node["diagnostics"].len > 0:
    warn(prefix & $node["diagnostics"].len & " documentation warning(s)")

proc printDocFailures(node: JsonNode) =
  if node.hasKey("commands"):
    for command in node["commands"].getElems():
      if command["exitCode"].getInt() != 0:
        let output = command["compilerOutput"].getStr()
        if output.len > 0:
          echo output
  elif node{"workspace"}.getBool(false):
    for member in node["members"].getElems():
      printDocFailures(member["docs"])

proc printDocResult(node: JsonNode) =
  if node{"workspace"}.getBool(false):
    for member in node["members"].getElems():
      printDocSummary(member["docs"], member["path"].getStr() & ": ")
  else:
    printDocSummary(node)

proc firstDocPath(node: JsonNode): string =
  if node{"workspace"}.getBool(false):
    for member in node["members"].getElems():
      result = firstDocPath(member["docs"])
      if result.len > 0:
        return
    return
  result = node{"primaryPath"}.getStr("")

proc openDocResult(node: JsonNode) =
  let path = firstDocPath(node)
  if path.len > 0 and fileExists(path):
    info("opening docs...")
    try:
      discard execShellCmd("xdg-open " & quoteShell(path))
    except CatchableError:
      discard

proc watchLoop*(opts: CliOptions) =
  ## Watch project files and rerun the selected build-like command.
  let projectDir = try: findProjectRoot() except: getCurrentDir()
  info("watching " & projectDir & " for changes (Ctrl+C to stop)")

  proc triggerBuild() =
    try:
      case opts.command
      of cmdBuild:
        let cfg = loadEffectiveConfig(projectDir)
        discard buildSingleTarget(cfg, opts.profile, projectDir, opts.verbose,
          selectedFeatures(opts, cfg))
      of cmdRun:
        let cfg = loadEffectiveConfig(projectDir)
        runTarget(cfg, -1, opts.profile, projectDir, opts.args, opts.verbose,
          selectedFeatures(opts, cfg))
        quit(0)
      else:
        let cfg = loadEffectiveConfig(projectDir)
        discard buildSingleTarget(cfg, opts.profile, projectDir, opts.verbose,
          selectedFeatures(opts, cfg))
    except CatchableError as e:
      error("build failed: " & e.msg)

  when defined(linux):
    let watchMask = IN_CLOSE_WRITE or IN_MOVED_TO or IN_CREATE or IN_DELETE or
        IN_MOVE_SELF or IN_DELETE_SELF
    var inotifyFd = inotify_init()
    if inotifyFd < 0:
      warn("inotify unavailable, falling back to polling")
      inotifyFd = -1
    else:
      var wds: seq[cint]
      let srcDir = projectDir / "src"
      if dirExists(srcDir):
        wds.add(inotify_add_watch(cint(inotifyFd), srcDir.cstring, uint32(watchMask)))
        for kind, path in walkDir(srcDir):
          if kind == pcDir:
            wds.add(inotify_add_watch(cint(inotifyFd), path.cstring, uint32(watchMask)))
      let testsDir = projectDir / "tests"
      if dirExists(testsDir):
        wds.add(inotify_add_watch(cint(inotifyFd), testsDir.cstring, uint32(watchMask)))

      info("watching " & $wds.len & " directories via inotify")
      let bufferSize = 4096
      var buffer = newString(bufferSize)
      var lastEvent = getMonoTime()
      var debounce = initDuration(milliseconds = 200)

      while inotifyFd >= 0:
        let bytesRead = posix.read(cint(inotifyFd), addr buffer[0], bufferSize)
        if bytesRead > 0:
          let now = getMonoTime()
          if now - lastEvent > debounce:
            lastEvent = now
            info("changes detected, rebuilding...")
            triggerBuild()
        else:
          break

      for wd in wds:
        discard inotify_rm_watch(inotifyFd, wd)
      discard posix.close(cint(inotifyFd))
    if inotifyFd >= 0:
      return

  # Fallback: simple polling
  var mtimes = initTable[string, Time]()
  while true:
    var changed = false
    let srcDir = projectDir / "src"
    if dirExists(srcDir):
      for f in walkDirRec(srcDir, yieldFilter = {pcFile}):
        if not f.endsWith(".nim"):
          continue
        let t = getLastModificationTime(f)
        if not mtimes.hasKey(f) or mtimes[f] != t:
          mtimes[f] = t
          changed = true
    if changed:
      info("changes detected, rebuilding...")
      triggerBuild()
    os.sleep(500)

proc addCompileEntry(entries: var seq[JsonNode]; projectDir, file: string;
    flags: openArray[string]; outDir: string) =
  var entry = newJObject()
  entry["directory"] = %projectDir
  entry["file"] = %absolutePath(file)
  var args = newJArray()
  args.add %detectNimCompiler()
  args.add %"check"
  for fl in flags:
    args.add %fl
  args.add %("--out:" & (outDir / splitFile(file).name))
  args.add %file
  entry["arguments"] = args
  entries.add(entry)

proc generateCompileCommands*(projectDir: string; profile: string;
    featureSelection: FeatureSelection = FeatureSelection()) =
  ## Generate `compile_commands.json` for one project.
  let cfg = parseBauConfigFile(projectDir / ConfigFileName)
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let profName = profile
  var prof = initProfileInfo()
  if profName.len > 0 and cfg.profiles.hasKey(profName):
    prof = resolveProfile(cfg.profiles, profName)
  let outDir = absolutePath(projectDir) / BuildDirName / profName
  let flags = collectCompilerFlags(prof, cfg.build.kind, outDir, sourceDir,
    projectDir, cfg, featureSelection)

  var entries: seq[JsonNode]
  var seen = initHashSet[string]()
  let absSource = projectDir / sourceDir
  if dirExists(absSource):
    for f in walkDirRec(absSource, yieldFilter = {pcFile}):
      if f.endsWith(".nim") and not seen.contains(f):
        seen.incl(f)
        entries.addCompileEntry(projectDir, f, flags, outDir)
  let testDir = projectDir / "tests"
  if dirExists(testDir):
    let testFlags = collectCompilerFlags(prof, bkTest, outDir, sourceDir,
      projectDir, cfg, featureSelection)
    for f in walkDirRec(testDir, yieldFilter = {pcFile}):
      if f.endsWith(".nim") and not seen.contains(f):
        seen.incl(f)
        entries.addCompileEntry(projectDir, f, testFlags, outDir)

  saveFile(projectDir / "compile_commands.json", pretty(%*entries))
  success("compile_commands.json generated")

proc aliasOptions(opts: CliOptions): Option[CliOptions] =
  if opts.aliasResolved or opts.rawCommand.len == 0:
    return none(CliOptions)
  try:
    let projectDir = findProjectRoot()
    let cfg = loadEffectiveConfig(projectDir)
    if not cfg.aliases.hasKey(opts.rawCommand):
      return none(CliOptions)
    var params = parseCommandLine(cfg.aliases[opts.rawCommand])
    if params.len == 0:
      raise newException(ValueError, "alias is empty: " & opts.rawCommand)
    if opts.rawArgs.len > 1:
      params.add(opts.rawArgs[1..^1])
    var expanded = parseCliOptions(params)
    expanded.aliasResolved = true
    result = some(expanded)
  except IOError:
    result = none(CliOptions)

proc dispatchCommand*(opts: CliOptions) =
  ## Dispatch parsed CLI options to the selected command implementation.
  if opts.command notin {cmdHelp, cmdVersion}:
    let aliased = aliasOptions(opts)
    if aliased.isSome:
      dispatchCommand(aliased.get())
      return

  setOutputOptions(opts.quiet, opts.color)
  putEnv("BAU_JOBS", $max(1, opts.jobs))
  putEnv("BAU_COLOR", opts.color)

  case opts.command
  of cmdVersion:
    printVersion()
    return
  of cmdHelp:
    printHelp()
    return
  else:
    discard

  if opts.watch:
    watchLoop(opts)
    return

  let timings = opts.timings
  var t0 = getMonoTime()

  case opts.command
  of cmdInit:
    let projectDir = getCurrentDir()
    if not opts.force and fileExists(projectDir / ConfigFileName):
      raise newException(IOError, "project already exists at " & projectDir &
        " (use --force to overwrite)")
    let defaultName = extractFilename(projectDir)
    let info = completeProjectInitInfo(opts.initInfo, defaultName)
    initProject(projectDir, info, opts.force)

  of cmdNew:
    if opts.args.len < 1:
      error("bau new requires a path")
      quit(1)
    let path = opts.args[0]
    var info = opts.initInfo
    if info.name.len == 0:
      info.name = extractFilename(path)
    initNew(path, info, opts.force)

  of cmdConvert:
    convertCommand(opts)

  of cmdBuild:
    let projectDir = findProjectRoot()
    let wsCfg = loadWorkspaceConfig(projectDir / ConfigFileName)
    if isSome(wsCfg):
      let members = resolveWorkspaceMembers(projectDir, get(wsCfg))
      info("workspace with " & $members.len & " member(s)")
      for member in members:
        let memberDir = member.projectDir
        if not fileExists(memberDir / ConfigFileName):
          warn("member '" & member.path & "' has no bau.toml, skipping")
        else:
          info("building workspace member: " & member.path)
          let cfg = loadEffectiveConfig(memberDir, projectDir)
          buildAllTargets(cfg, opts.profile, memberDir, opts.verbose,
            selectedFeatures(opts, cfg))
      success("workspace built")
      return

    let cfg = loadEffectiveConfig(projectDir)
    let featureSelection = selectedFeatures(opts, cfg)
    if opts.args.len > 0:
      discard buildTargetByName(cfg, opts.args[0], opts.profile, projectDir,
        opts.verbose, featureSelection)
    else:
      buildAllTargets(cfg, opts.profile, projectDir, opts.verbose,
        featureSelection)

  of cmdRun:
    let projectDir = findProjectRoot()
    let cfg = loadEffectiveConfig(projectDir)
    let featureSelection = selectedFeatures(opts, cfg)
    if opts.args.len > 0 and findTargetIndex(cfg, opts.args[0]) >= 0:
      let runArgs = if opts.passthroughArgs.len > 0:
                      opts.passthroughArgs
                    elif opts.args.len > 1:
                      opts.args[1..^1]
                    else:
                      @[]
      runTargetByName(cfg, opts.args[0], opts.profile, projectDir,
        runArgs, opts.verbose, featureSelection)
    else:
      let runArgs = if opts.passthroughArgs.len > 0:
                      opts.passthroughArgs
                    else:
                      opts.args
      runTarget(cfg, -1, opts.profile, projectDir, runArgs, opts.verbose,
        featureSelection)

  of cmdTest:
    let projectDir = findProjectRoot()
    let cfg = loadEffectiveConfig(projectDir)
    if not dirExists(projectDir / "tests") and cfg.test.runner.len == 0:
      warn("no tests directory found")
      return
    let filter = if opts.args.len > 0: opts.args[0] else: ""
    let testResult = runTests(cfg, projectDir, TestRunOptions(
      profile: opts.profile,
      filter: filter,
      changed: opts.changed,
      since: opts.since,
      passthroughArgs: opts.passthroughArgs,
      showOutput: effectiveTestOutputMode(cfg, opts.testShowOutput),
      verbose: opts.verbose,
      featureSelection: selectedFeatures(opts, cfg)))
    echo ""
    info("test results: " & $testResult.passed & " passed, " &
      $testResult.failed & " failed")
    if testResult.failed > 0:
      quit(1)

  of cmdCheck:
    let projectDir = try: findProjectRoot() except: getCurrentDir()
    let cfg = try: loadEffectiveConfig(projectDir) except: findProjectConfig(projectDir)
    let featureSelection = selectedFeatures(opts, cfg)
    let profName = opts.profile
    let prof = if cfg.profiles.hasKey(profName):
                 resolveProfile(cfg.profiles, profName)
               else:
                 initProfileInfo()
    let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
    let outDir = absolutePath(projectDir) / BuildDirName / profName
    let flags = collectCompilerFlags(prof, cfg.build.kind, outDir, sourceDir,
      projectDir, cfg, featureSelection)
    var mains: seq[string]
    if opts.allTargets:
      if cfg.build.main.len > 0:
        mains.add(cfg.build.main)
      for target in cfg.targets:
        if target.main.len > 0:
          mains.add(target.main)
    else:
      mains.add(cfg.build.main)
    for mainFile in mains:
      var checkArgs = @["check"]
      checkArgs.add(flags)
      checkArgs.add(mainFile)
      runCmdLive(detectNimCompiler(), checkArgs, projectDir)
      success("check   " & mainFile)

  of cmdDoc:
    let projectDir = try: findProjectRoot() except: getCurrentDir()
    let op = docOperation(projectDir, opts.toOperationOptions())
    if opts.json or opts.format == "json":
      echo pretty(op.json)
    else:
      printDocResult(op.json)
      if not op.ok:
        printDocFailures(op.json)
    if not op.ok:
      quit(1)
    if opts.open:
      openDocResult(op.json)

  of cmdInstall, cmdUpdate, cmdUninstall:
    installCommand(opts)

  of cmdClean:
    cleanBuild()

  of cmdDeps:
    depsCommand(opts)

  of cmdAdd:
    let projectDir = findProjectRoot()
    if opts.args.len < 1:
      error("bau add requires a dependency name")
      quit(1)
    let depName = opts.args[0]
    var opOpts = opts.toOperationOptions()
    opOpts.depName = depName
    try:
      if opts.args.len > 1:
        opOpts.applyDependencyArgs(opts.args[1..^1])
    except ValueError as e:
      error(e.msg)
      quit(1)
    let op = addDependencyOperation(projectDir, opOpts)
    if not op.ok:
      error(op.json{"error"}.getStr(op.output))
      quit(1)
    success("added dependency '" & depName & "' to " & ConfigFileName)

  of cmdRemove:
    let projectDir = findProjectRoot()
    if opts.args.len < 1:
      error("bau remove requires a dependency name")
      quit(1)
    let depName = opts.args[0]
    var opOpts = opts.toOperationOptions()
    opOpts.depName = depName
    let op = removeDependencyOperation(projectDir, opOpts)
    if not op.ok:
      error(op.json{"error"}.getStr(op.output))
      quit(1)
    success("removed dependency '" & depName & "' from " & ConfigFileName)

  of cmdTask:
    let taskName = opts.taskName
    let projectDir = try: findProjectRoot() except: getCurrentDir()
    let cfg = try: loadEffectiveConfig(projectDir) except: initBauConfig()
    if opts.help and taskName.len == 0:
      printTaskCommandHelp()
      return
    if opts.list:
      printTaskList(cfg)
      return
    if taskName.len == 0:
      error("bau task requires a task name")
      quit(1)
    if opts.help:
      printTaskDetails(cfg, projectDir, opts)
      return
    if opts.args.len > 0:
      error("unexpected task argument(s): " & opts.args.join(" ") &
        " (use -- before task args)")
      quit(1)
    let featureSelection = selectedFeatures(opts, cfg)
    let ok = runTaskByName(cfg, taskName, projectDir, TaskRunOptions(
      profile: opts.profile,
      verbose: opts.verbose,
      dryRun: opts.dryRun,
      force: opts.force,
      keepGoing: opts.keepGoing,
      features: featureSelection,
      taskArgs: opts.passthroughArgs))
    if not ok:
      quit(1)

  of cmdFmt:
    fmtCommand(opts)

  of cmdLint:
    lintCommand(opts)

  of cmdCi:
    ciCommand(opts)

  of cmdOutdated:
    outdatedCommand(opts)

  of cmdTree:
    treeCommand(opts)

  of cmdExplain:
    explainCommand(opts)

  of cmdPublish:
    publishCommand(opts)

  of cmdBump:
    bumpCommand(opts)

  of cmdShell:
    shellCommand(opts)

  of cmdShellInit:
    shellInitCommand(opts)

  of cmdPlugin:
    pluginCommand(opts)

  of cmdCompileCommands:
    let projectDir = findProjectRoot()
    discard compileCommandsOperation(projectDir, opts.toOperationOptions())
    success("compile_commands.json generated")

  of cmdCiTemplate:
    let projectDir = try: findProjectRoot() except: getCurrentDir()
    let kind = if opts.args.len > 0: opts.args[0] else: "github"
    generateCiTemplate(kind, projectDir)

  of cmdMetadata:
    metadataCommand(opts)

  of cmdGraph:
    graphCommand(opts)

  of cmdQuery:
    queryCommand(opts)

  of cmdTailor:
    tailorCommand(opts)

  of cmdPackage:
    packageCommand(opts)

  of cmdEnv:
    envCommand(opts)

  of cmdAffected:
    affectedCommand(opts)

  of cmdCache:
    cacheCommand(opts)

  of cmdDoctor:
    doctorCommand(opts)

  else:
    error("unknown command")
    quit(1)

  if timings:
    let elapsed = (getMonoTime() - t0).inMilliseconds
    echo ""
    info("elapsed: " & $elapsed & " ms")
