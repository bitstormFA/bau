## Parses and merges Bau configuration files.

import std/[options, tables, sets, os, strutils]
import parsetoml
import bau/util

type
  BuildKind* = enum ## Build artifact category requested for a target.
    bkBin = "bin"   ## Build an executable binary.
    bkLib = "lib"   ## Build a library module.
    bkTest = "test" ## Build a test target.

  PackageInfo* = object        ## Package metadata read from the `[package]` table.
    name*: string              ## Package name used for defaults and generated metadata.
    version*: string           ## Package version string.
    description*: string       ## Human-readable package summary.
    authors*: seq[string]      ## Package author names or contact strings.
    license*: string           ## SPDX-style or free-form license identifier.
    edition*: string           ## Bau configuration edition used by this project.
    repository*: string        ## Public source repository URL.
    homepage*: string          ## Project homepage URL.
    includeFiles*: seq[string] ## Extra package file patterns to include.
    excludeFiles*: seq[string] ## Package file patterns to exclude.

  BuildInfo* = object ## Default build target settings from `[build]`.
    name*: string     ## Optional CLI name for the default target.
    kind*: BuildKind  ## Default artifact category.
    source*: string   ## Source directory relative to the project root.
    main*: string     ## Main Nim source file relative to the project root.
    output*: string   ## Default output binary or library name.
    nim*: string      ## Explicit Nim compiler command, if configured.
    backend*: string  ## Compiler backend such as `c`, `cpp`, or `js`.
    includeDefault*: bool ## Whether `bau build` includes the default target when explicit targets exist.

  ProfileInfo* = object            ## Compiler settings attached to a named profile.
    flags*: seq[string]            ## Raw Nim compiler flags.
    gc*: string                    ## Nim memory-management strategy.
    define*: Table[string, string] ## `--define` values keyed by symbol name.
    extends*: string               ## Parent profile name to inherit before merging.
    backend*: string               ## Profile-specific compiler backend override.

  DepInfo* = object           ## Dependency requirement or source override.
    url*: Option[string]      ## Git URL for Git-sourced dependencies.
    tag*: Option[string]      ## Git tag to check out.
    branch*: Option[string]   ## Git branch to track.
    rev*: Option[string]      ## Exact Git revision to use.
    path*: Option[string]     ## Local path dependency location.
    version*: Option[string]  ## Registry version requirement.
    registry*: Option[string] ## Named registry source to resolve through.
    optional*: bool           ## Whether the dependency is enabled only by features.

  SourceInfo* = object     ## Named package source used for dependency resolution.
    registry*: string      ## Remote Atlas registry URL.
    directory*: string     ## Local directory containing package sources.
    localRegistry*: string ## Local Atlas registry path.
    git*: string           ## Git repository backing this source.
    replaceWith*: string   ## Alternate source name that supersedes this one.

  ToolchainInfo* = object ## Minimum external tool versions required by a project.
    nim*: string   ## Nim compiler version requirement.
    atlas*: string ## Atlas version requirement.

  FeatureInfo* = object ## Feature declaration and what it enables.
    enables*: seq[string] ## Feature names or `dep:name` entries enabled together.

  GovernanceInfo* = object       ## Dependency policy configured for a project or workspace.
    blocked*: seq[string]        ## Dependency names that must not be used.
    trusted*: seq[string]        ## Dependency names approved by policy.
    minimumReleaseAgeHours*: int ## Minimum age for resolved package releases.

  CacheInfo* = object ## Task-cache location and remote cache behavior.
    dir*: string      ## Local cache directory relative to the project root.
    remote*: string   ## Remote cache URL or file path.
    read*: bool       ## Whether local or remote cache reads are allowed.
    write*: bool      ## Whether local or remote cache writes are allowed.

  InstallInfo* = object ## Defaults for installing built targets.
    dir*: string        ## Installation directory override.

  DocsInfo* = object           ## API documentation generation settings.
    outDir*: string            ## Documentation output directory.
    docRoot*: string           ## Nim doc source-root mode or URL root.
    entrypoints*: seq[string]  ## Explicit documentation entrypoint files.
    includeFiles*: seq[string] ## Additional documentation source patterns.
    excludeFiles*: seq[string] ## Documentation source patterns to skip.
    flags*: seq[string]        ## Additional Nim doc compiler flags.
    project*: bool             ## Whether to discover project modules automatically.
    index*: bool               ## Whether to generate Bau's documentation index page.
    runExamples*: bool         ## Whether Nim doc should compile runnable examples.
    includePrivate*: bool      ## Whether private symbols are included in API docs.
    sourceUrl*: string         ## Template URL for generated source links.
    configured*: bool          ## True when `[docs]` was present in config input.

  TestInfo* = object        ## Test discovery and runner settings from `[test]`.
    runner*: string         ## Explicit test runner file relative to the project root.
    profiles*: seq[string]  ## Profiles used as the test matrix.
    defaultProfile*: string ## Single profile used for fast local test runs.
    fullProfiles*: seq[string] ## Full profile matrix used by `bau test --full` and CI.
    recursive*: bool        ## Whether test file discovery descends into subdirectories.
    exclude*: seq[string]   ## Test filenames or relative paths to skip.
    showOutput*: string     ## Default test output mode: auto, always, or never.
    configured*: bool       ## True when `[test]` was present in config input.

  TargetInfo* = object             ## Explicit build target declaration.
    name*: string                  ## Target name used by CLI commands.
    kind*: BuildKind               ## Artifact category for this target.
    main*: string                  ## Target main source file.
    output*: string                ## Artifact output name, when it differs from `name`.
    source*: string                ## Source directory override for this target.
    paths*: seq[string]            ## Extra Nim import paths for this target.
    profile*: string               ## Default profile for this target.
    requiredFeatures*: seq[string] ## Features that must be enabled to build it.
    tags*: seq[string]             ## Free-form labels used by commands such as `affected`.

  ScriptInfo* = object           ## Legacy lifecycle hook commands.
    preBuild*: Option[string]    ## Command run before compiling.
    postBuild*: Option[string]   ## Command run after compiling.
    postInstall*: Option[string] ## Command run after installing.

  TaskInfo* = object               ## Declarative task or build-script command.
    name*: string                  ## Task name used for lookup and diagnostics.
    cmd*: string                   ## Command line to execute.
    command*: string               ## Built-in Bau command to execute instead of `cmd`.
    description*: string           ## Human-readable task summary.
    deps*: seq[string]             ## Task dependencies that must run first.
    inputs*: seq[string]           ## Input file patterns for freshness and cache keys.
    outputs*: seq[string]          ## Output file patterns produced by the task.
    cwd*: Option[string]           ## Working directory relative to the project root.
    env*: Table[string, string]    ## Environment variables set for the task.
    envInputs*: seq[string]        ## Environment variable names included in cache keys.
    watch*: seq[string]            ## Paths watched by long-running workflows.
    shell*: string                 ## Explicit shell command used to run `cmd`.
    profile*: string               ## Profile used when the task invokes a built-in command.
    cache*: bool                   ## Whether task outputs can be cached.
    acceptArgs*: bool              ## Whether `bau task <name> -- ...` is allowed.
    requiredFeatures*: seq[string] ## Features required before running this task.
    tags*: seq[string]             ## Free-form labels used by task selection.

  BauConfig* = object                     ## Fully parsed Bau project configuration.
    package*: PackageInfo                 ## Package metadata.
    build*: BuildInfo                     ## Default build settings.
    toolchain*: ToolchainInfo             ## Toolchain constraints.
    governance*: GovernanceInfo           ## Dependency policy.
    cache*: CacheInfo                     ## Task-cache configuration.
    install*: InstallInfo                 ## Install defaults.
    docs*: DocsInfo                       ## Documentation settings.
    test*: TestInfo                       ## Test runner and matrix settings.
    profiles*: Table[string, ProfileInfo] ## Profiles keyed by name.
    targets*: seq[TargetInfo]             ## Explicit build targets.
    deps*: Table[string, DepInfo]         ## Dependency requirements keyed by name.
    patches*: Table[string, DepInfo]      ## Root-level dependency replacements.
    sources*: Table[string, SourceInfo]   ## Named dependency sources.
    features*: Table[string, FeatureInfo] ## Feature declarations keyed by name.
    aliases*: Table[string, string]       ## Project command aliases keyed by command name.
    catalogs*: Table[string, Table[string,
        string]]                          ## Version catalogs keyed by catalog and dependency.
    scripts*: ScriptInfo                  ## Lifecycle hook commands.
    buildScripts*: seq[TaskInfo]          ## Build scripts that can emit compiler directives.
    tasks*: seq[TaskInfo]                 ## User-defined tasks.

  WorkspaceConfig* = object             ## Workspace-level defaults from `[workspace]`.
    members*: seq[string]               ## Workspace member path patterns.
    defaultMembers*: seq[string]        ## Members selected when no explicit subset is given.
    exclude*: seq[string]               ## Member path patterns to ignore.
    package*: PackageInfo               ## Package defaults inherited by members.
    deps*: Table[string, DepInfo]       ## Shared dependency defaults.
    sources*: Table[string, SourceInfo] ## Shared dependency sources.
    profiles*: Table[string, ProfileInfo] ## Shared profiles inherited by members.
    catalogs*: Table[string, Table[string, string]] ## Shared version catalogs.
    governance*: GovernanceInfo         ## Shared dependency policy.

  FullConfig* = object ## Optional global, workspace, and project config bundle.
    bau*: Option[BauConfig]             ## Project configuration, when present.
    workspace*: Option[WorkspaceConfig] ## Workspace configuration, when present.
    globalProfile*: Option[ProfileInfo] ## User-level profile defaults.
    globalTasks*: seq[TaskInfo]         ## User-level tasks appended to projects.

proc initPackageInfo*(): PackageInfo =
  ## Return package defaults used when `[package]` omits values.
  PackageInfo(edition: "2026")

proc initBuildInfo*(): BuildInfo =
  ## Return default build settings for a binary project.
  BuildInfo(kind: bkBin, source: "src")

proc initToolchainInfo*(): ToolchainInfo =
  ## Return empty toolchain constraints.
  ToolchainInfo()

proc initGovernanceInfo*(): GovernanceInfo =
  ## Return empty dependency-governance policy.
  GovernanceInfo()

proc initCacheInfo*(): CacheInfo =
  ## Return default local task-cache settings.
  CacheInfo(dir: BuildDirName / ".bau" / "cache", read: true, write: true)

proc initInstallInfo*(): InstallInfo =
  ## Return empty install settings.
  InstallInfo()

proc initDocsInfo*(): DocsInfo =
  ## Return default API documentation settings.
  DocsInfo(outDir: "docs", docRoot: "@path", project: true, index: true,
    runExamples: true)

proc initTestInfo*(): TestInfo =
  ## Return default test discovery and output settings.
  TestInfo(showOutput: "auto")

proc initProfileInfo*(): ProfileInfo =
  ## Return an empty compiler profile.
  ProfileInfo()

proc initBauConfig*(): BauConfig =
  ## Return a project configuration populated with Bau defaults.
  BauConfig(
    package: initPackageInfo(),
    build: initBuildInfo(),
    toolchain: initToolchainInfo(),
    governance: initGovernanceInfo(),
    cache: initCacheInfo(),
    install: initInstallInfo(),
    docs: initDocsInfo(),
    test: initTestInfo())

proc defaultTargetName*(cfg: BauConfig): string =
  ## Return the CLI identity for the default `[build]` target.
  if cfg.build.name.len > 0:
    cfg.build.name
  elif cfg.build.output.len > 0:
    cfg.build.output
  else:
    cfg.package.name

# ---- TOML → Nim type converters ----

proc getStrOpt(table: TomlValueRef; key: string): Option[string] =
  if table.hasKey(key):
    some(table[key].getStr())
  else:
    none(string)

proc getSeq(table: TomlValueRef; key: string): seq[string] =
  if table.hasKey(key) and table[key].kind == TomlValueKind.Array:
    for item in table[key].getElems():
      result.add(item.getStr())

proc getBool(table: TomlValueRef; key: string; defaultValue: bool): bool =
  result = defaultValue
  if table.hasKey(key) and table[key].kind == TomlValueKind.Bool:
    result = table[key].getBool()

proc parseScriptInfo(table: TomlValueRef): ScriptInfo =
  result.preBuild = getStrOpt(table, "preBuild")
  result.postBuild = getStrOpt(table, "postBuild")
  result.postInstall = getStrOpt(table, "postInstall")

proc parsePackageInfo(table: TomlValueRef): PackageInfo =
  result = initPackageInfo()
  if table.hasKey("name"): result.name = table["name"].getStr()
  if table.hasKey("version"): result.version = table["version"].getStr()
  if table.hasKey("description"): result.description = table[
      "description"].getStr()
  result.authors = getSeq(table, "authors")
  if table.hasKey("license"): result.license = table["license"].getStr()
  if table.hasKey("edition"): result.edition = table["edition"].getStr()
  if table.hasKey("repository"): result.repository = table["repository"].getStr()
  if table.hasKey("homepage"): result.homepage = table["homepage"].getStr()
  result.includeFiles = getSeq(table, "include")
  result.excludeFiles = getSeq(table, "exclude")

proc parseBuildKind(str: string): BuildKind =
  case str
  of "bin": bkBin
  of "lib": bkLib
  of "test": bkTest
  else: raise newException(ValueError, "unknown build kind: " & str)

proc parseBuildInfo(table: TomlValueRef): BuildInfo =
  result = initBuildInfo()
  if table.hasKey("name"): result.name = table["name"].getStr()
  if table.hasKey("kind"): result.kind = parseBuildKind(table["kind"].getStr())
  if table.hasKey("source"): result.source = table["source"].getStr()
  if table.hasKey("main"): result.main = table["main"].getStr()
  if table.hasKey("output"): result.output = table["output"].getStr()
  if table.hasKey("nim"): result.nim = table["nim"].getStr()
  if table.hasKey("backend"): result.backend = table["backend"].getStr()
  result.includeDefault = getBool(table, "includeDefault", false)

proc parseProfileInfo(table: TomlValueRef): ProfileInfo =
  result.flags = getSeq(table, "flags")
  if table.hasKey("gc"): result.gc = table["gc"].getStr()
  if table.hasKey("extends"): result.extends = table["extends"].getStr()
  if table.hasKey("backend"): result.backend = table["backend"].getStr()
  if table.hasKey("define"):
    let defTable = table["define"].getTable()
    for key, val in defTable.pairs:
      result.define[key] = val.getStr()

proc parseDepInfo(value: TomlValueRef): DepInfo =
  case value.kind
  of TomlValueKind.String:
    result.version = some(value.getStr())
  of TomlValueKind.Table:
    let t = value.getTable()
    if t.hasKey("git"): result.url = some(t["git"].getStr())
    if t.hasKey("tag"): result.tag = some(t["tag"].getStr())
    if t.hasKey("branch"): result.branch = some(t["branch"].getStr())
    if t.hasKey("rev"): result.rev = some(t["rev"].getStr())
    if t.hasKey("path"): result.path = some(t["path"].getStr())
    if t.hasKey("version"): result.version = some(t["version"].getStr())
    if t.hasKey("registry"): result.registry = some(t["registry"].getStr())
    result.optional = getBool(value, "optional", false)
  else:
    discard

proc parseSourceInfo(table: TomlValueRef): SourceInfo =
  if table.hasKey("registry"): result.registry = table["registry"].getStr()
  if table.hasKey("directory"): result.directory = table["directory"].getStr()
  if table.hasKey("localRegistry"):
    result.localRegistry = table["localRegistry"].getStr()
  if table.hasKey("git"): result.git = table["git"].getStr()
  if table.hasKey("replaceWith"):
    result.replaceWith = table["replaceWith"].getStr()

proc parseToolchainInfo(table: TomlValueRef): ToolchainInfo =
  if table.hasKey("nim"): result.nim = table["nim"].getStr()
  if table.hasKey("atlas"): result.atlas = table["atlas"].getStr()

proc parseGovernanceInfo(table: TomlValueRef): GovernanceInfo =
  result.blocked = getSeq(table, "blocked")
  result.trusted = getSeq(table, "trusted")
  if table.hasKey("minimumReleaseAgeHours"):
    result.minimumReleaseAgeHours = table["minimumReleaseAgeHours"].getInt()

proc parseCacheInfo(table: TomlValueRef): CacheInfo =
  result = initCacheInfo()
  if table.hasKey("dir"): result.dir = table["dir"].getStr()
  if table.hasKey("remote"): result.remote = table["remote"].getStr()
  result.read = getBool(table, "read", result.read)
  result.write = getBool(table, "write", result.write)

proc parseInstallInfo(table: TomlValueRef): InstallInfo =
  if table.hasKey("dir"): result.dir = table["dir"].getStr()

proc parseDocsInfo(table: TomlValueRef): DocsInfo =
  result = initDocsInfo()
  result.configured = true
  if table.hasKey("outDir"): result.outDir = table["outDir"].getStr()
  if table.hasKey("docRoot"): result.docRoot = table["docRoot"].getStr()
  result.entrypoints = getSeq(table, "entrypoints")
  result.includeFiles = getSeq(table, "include")
  result.excludeFiles = getSeq(table, "exclude")
  result.flags = getSeq(table, "flags")
  result.project = getBool(table, "project", result.project)
  result.index = getBool(table, "index", result.index)
  result.runExamples = getBool(table, "runExamples", result.runExamples)
  result.includePrivate = getBool(table, "includePrivate",
    result.includePrivate)
  if table.hasKey("sourceUrl"): result.sourceUrl = table["sourceUrl"].getStr()

proc parseTestInfo(table: TomlValueRef): TestInfo =
  result = initTestInfo()
  result.configured = true
  if table.hasKey("runner"): result.runner = table["runner"].getStr()
  result.profiles = getSeq(table, "profiles")
  if table.hasKey("defaultProfile"):
    result.defaultProfile = table["defaultProfile"].getStr()
  result.fullProfiles = getSeq(table, "fullProfiles")
  result.recursive = getBool(table, "recursive", result.recursive)
  result.exclude = getSeq(table, "exclude")
  if table.hasKey("showOutput"):
    result.showOutput = table["showOutput"].getStr()

proc parseTargetInfo(table: TomlValueRef): TargetInfo =
  result.name = table["name"].getStr()
  if table.hasKey("kind"): result.kind = parseBuildKind(table["kind"].getStr())
  if table.hasKey("main"): result.main = table["main"].getStr()
  if table.hasKey("output"): result.output = table["output"].getStr()
  if table.hasKey("source"): result.source = table["source"].getStr()
  result.paths = getSeq(table, "paths")
  if table.hasKey("profile"): result.profile = table["profile"].getStr()
  result.requiredFeatures = getSeq(table, "requiredFeatures")
  result.tags = getSeq(table, "tags")

proc parseTaskInfo(table: TomlValueRef): TaskInfo =
  result.name = table["name"].getStr()
  if table.hasKey("cmd"):
    result.cmd = table["cmd"].getStr()
  if table.hasKey("command"):
    result.command = table["command"].getStr()
  if table.hasKey("description"):
    result.description = table["description"].getStr()
  result.deps = getSeq(table, "deps")
  result.inputs = getSeq(table, "inputs")
  result.outputs = getSeq(table, "outputs")
  result.cwd = getStrOpt(table, "cwd")
  if table.hasKey("shell"):
    result.shell = table["shell"].getStr()
  if table.hasKey("profile"):
    result.profile = table["profile"].getStr()
  if table.hasKey("watch"):
    result.watch = getSeq(table, "watch")
  result.envInputs = getSeq(table, "envInputs")
  result.cache = getBool(table, "cache", false)
  result.acceptArgs = getBool(table, "acceptArgs", false)
  result.requiredFeatures = getSeq(table, "requiredFeatures")
  result.tags = getSeq(table, "tags")
  if table.hasKey("env"):
    let envTable = table["env"].getTable()
    for key, val in envTable.pairs:
      result.env[key] = val.getStr()

proc parseFeatureInfo(value: TomlValueRef): FeatureInfo =
  case value.kind
  of TomlValueKind.Array:
    for item in value.getElems():
      result.enables.add(item.getStr())
  of TomlValueKind.String:
    result.enables.add(value.getStr())
  else:
    discard

proc parseCatalogTable(table: TomlValueRef): Table[string, string] =
  if table.kind == TomlValueKind.Table:
    for key, val in table.getTable().pairs:
      if val.kind == TomlValueKind.String:
        result[key] = val.getStr()

proc parseCatalogs(root: TomlValueRef): Table[string, Table[string, string]] =
  if root.hasKey("catalog") and root["catalog"].kind == TomlValueKind.Table:
    result["default"] = parseCatalogTable(root["catalog"])
  if root.hasKey("catalogs") and root["catalogs"].kind == TomlValueKind.Table:
    for name, val in root["catalogs"].getTable().pairs:
      if val.kind == TomlValueKind.Table:
        result[name] = parseCatalogTable(val)

proc resolveCatalogVersion(catalogs: Table[string, Table[string, string]];
    depName, value: string): string =
  if not value.startsWith("catalog:"):
    return value
  let catalogName = if value.len == "catalog:".len:
                      "default"
                    else:
                      value["catalog:".len..^1]
  if catalogs.hasKey(catalogName) and catalogs[catalogName].hasKey(depName):
    return catalogs[catalogName][depName]
  raise newException(ValueError, "catalog entry not found for dependency '" &
    depName & "' in catalog '" & catalogName & "'")

proc resolveCatalogDeps*(cfg: var BauConfig) =
  ## Replace `catalog:` dependency version references with concrete catalog values.
  for name, dep in cfg.deps.mpairs:
    if dep.version.isSome:
      dep.version = some(resolveCatalogVersion(cfg.catalogs, name,
        dep.version.get()))

proc parseBauConfig*(data: string; fileName: string = ""): BauConfig =
  ## Parse TOML configuration text into a `BauConfig`.
  ##
  ## `fileName` is used only for parser diagnostics.
  let root = parsetoml.parseString(data, fileName)
  result = initBauConfig()
  result.catalogs = parseCatalogs(root)

  if root.hasKey("package"):
    result.package = parsePackageInfo(root["package"])
  else:
    result.package = initPackageInfo()

  if root.hasKey("build"):
    result.build = parseBuildInfo(root["build"])
  else:
    result.build = initBuildInfo()

  if root.hasKey("toolchain") and root["toolchain"].kind == TomlValueKind.Table:
    result.toolchain = parseToolchainInfo(root["toolchain"])
  else:
    result.toolchain = initToolchainInfo()

  if root.hasKey("governance") and
      root["governance"].kind == TomlValueKind.Table:
    result.governance = parseGovernanceInfo(root["governance"])

  if root.hasKey("cache") and root["cache"].kind == TomlValueKind.Table:
    result.cache = parseCacheInfo(root["cache"])

  if root.hasKey("install") and root["install"].kind == TomlValueKind.Table:
    result.install = parseInstallInfo(root["install"])

  if root.hasKey("docs") and root["docs"].kind == TomlValueKind.Table:
    result.docs = parseDocsInfo(root["docs"])

  if root.hasKey("test") and root["test"].kind == TomlValueKind.Table:
    result.test = parseTestInfo(root["test"])

  for key, val in root.getTable().pairs:
    case key
    of "profile":
      # [profile.*] tables are merged into one table by parsetoml
      # but actually parsetoml just puts profile as a key with a subtable
      if val.kind == TomlValueKind.Table:
        let profiles = val.getTable()
        for pkey, pval in profiles.pairs:
          if pval.kind == TomlValueKind.Table:
            result.profiles[pkey] = parseProfileInfo(pval)
    of "targets":
      if val.kind == TomlValueKind.Array:
        for item in val.getElems():
          result.targets.add(parseTargetInfo(item))
    of "dependencies":
      if val.kind == TomlValueKind.Table:
        for dkey, dval in val.getTable().pairs:
          result.deps[dkey] = parseDepInfo(dval)
    of "patch":
      if val.kind == TomlValueKind.Table:
        for dkey, dval in val.getTable().pairs:
          result.patches[dkey] = parseDepInfo(dval)
    of "source":
      if val.kind == TomlValueKind.Table:
        for skey, sval in val.getTable().pairs:
          if sval.kind == TomlValueKind.Table:
            result.sources[skey] = parseSourceInfo(sval)
    of "features":
      if val.kind == TomlValueKind.Table:
        for fkey, fval in val.getTable().pairs:
          result.features[fkey] = parseFeatureInfo(fval)
    of "aliases":
      if val.kind == TomlValueKind.Table:
        for alias, target in val.getTable().pairs:
          if target.kind == TomlValueKind.String:
            result.aliases[alias] = target.getStr()
    of "catalog", "catalogs", "governance", "cache", "install", "docs",
        "test":
      discard
    of "scripts":
      if val.kind == TomlValueKind.Table:
        result.scripts = parseScriptInfo(val)
    of "buildScripts":
      if val.kind == TomlValueKind.Array:
        for item in val.getElems():
          result.buildScripts.add(parseTaskInfo(item))
    of "tasks":
      if val.kind == TomlValueKind.Array:
        for item in val.getElems():
          result.tasks.add(parseTaskInfo(item))
    else:
      discard
  resolveCatalogDeps(result)

proc parseBauConfigFile*(path: string): BauConfig =
  ## Load and parse a `bau.toml` file, raising on missing or invalid paths.
  if not fileExists(path):
    raise newException(IOError, "config file not found: " & path)
  if path == "":
    raise newException(ValueError, "config path is empty")
  parseBauConfig(readFileChecked(path), path)

proc parseWorkspaceConfig(table: TomlValueRef): WorkspaceConfig =
  result.members = getSeq(table, "members")
  result.defaultMembers = getSeq(table, "defaultMembers")
  result.exclude = getSeq(table, "exclude")
  if table.hasKey("catalog") and table["catalog"].kind == TomlValueKind.Table:
    result.catalogs["default"] = parseCatalogTable(table["catalog"])
  if table.hasKey("catalogs") and table["catalogs"].kind == TomlValueKind.Table:
    for name, val in table["catalogs"].getTable().pairs:
      if val.kind == TomlValueKind.Table:
        result.catalogs[name] = parseCatalogTable(val)
  if table.hasKey("governance") and
      table["governance"].kind == TomlValueKind.Table:
    result.governance = parseGovernanceInfo(table["governance"])
  if table.hasKey("package") and table["package"].kind == TomlValueKind.Table:
    result.package = parsePackageInfo(table["package"])
  if table.hasKey("dependencies") and table["dependencies"].kind ==
      TomlValueKind.Table:
    for dkey, dval in table["dependencies"].getTable().pairs:
      result.deps[dkey] = parseDepInfo(dval)
  if table.hasKey("source") and table["source"].kind == TomlValueKind.Table:
    for skey, sval in table["source"].getTable().pairs:
      if sval.kind == TomlValueKind.Table:
        result.sources[skey] = parseSourceInfo(sval)
  if table.hasKey("profile") and table["profile"].kind == TomlValueKind.Table:
    for pkey, pval in table["profile"].getTable().pairs:
      if pval.kind == TomlValueKind.Table:
        result.profiles[pkey] = parseProfileInfo(pval)

proc parseTasksToml*(data: string): seq[TaskInfo] =
  ## Parse a standalone task TOML document into task definitions.
  let root = parsetoml.parseString(data)
  if root.hasKey("tasks") and root["tasks"].kind == TomlValueKind.Array:
    for item in root["tasks"].getElems():
      result.add(parseTaskInfo(item))

# ---- Config merging ----

proc mergeTables[A, B](target: var Table[A, B]; source: Table[A, B]) =
  for key, val in source.pairs:
    target[key] = val

proc mergeProfile*(base: var ProfileInfo; override: ProfileInfo) =
  ## Merge a profile override into `base`.
  ##
  ## Flags and defines are additive; scalar fields replace only when populated.
  if override.flags.len > 0:
    base.flags.add(override.flags)
  if override.gc.len > 0:
    base.gc = override.gc
  if override.define.len > 0:
    mergeTables(base.define, override.define)
  if override.extends.len > 0:
    base.extends = override.extends
  if override.backend.len > 0:
    base.backend = override.backend

proc mergePackageDefaults*(base: var PackageInfo; defaults: PackageInfo) =
  ## Fill missing package fields in `base` from workspace defaults.
  if base.name.len == 0:
    base.name = defaults.name
  if base.version.len == 0:
    base.version = defaults.version
  if base.description.len == 0:
    base.description = defaults.description
  if base.authors.len == 0:
    base.authors = defaults.authors
  if base.license.len == 0:
    base.license = defaults.license
  if base.edition.len == 0:
    base.edition = defaults.edition
  if base.repository.len == 0:
    base.repository = defaults.repository
  if base.homepage.len == 0:
    base.homepage = defaults.homepage
  if base.includeFiles.len == 0:
    base.includeFiles = defaults.includeFiles
  if base.excludeFiles.len == 0:
    base.excludeFiles = defaults.excludeFiles

proc applyWorkspaceDefaults*(cfg: var BauConfig; ws: WorkspaceConfig) =
  ## Apply workspace defaults to a project configuration.
  ##
  ## Project-local values win over workspace defaults except for additive
  ## policy lists and merged profiles.
  mergePackageDefaults(cfg.package, ws.package)
  for name, catalog in ws.catalogs.pairs:
    if cfg.catalogs.hasKey(name):
      var merged = catalog
      for depName, version in cfg.catalogs[name].pairs:
        merged[depName] = version
      cfg.catalogs[name] = merged
    else:
      cfg.catalogs[name] = catalog
  for name, dep in ws.deps.pairs:
    if not cfg.deps.hasKey(name):
      cfg.deps[name] = dep
  for name, source in ws.sources.pairs:
    if not cfg.sources.hasKey(name):
      cfg.sources[name] = source
  for name, prof in ws.profiles.pairs:
    if cfg.profiles.hasKey(name):
      var merged = prof
      mergeProfile(merged, cfg.profiles[name])
      cfg.profiles[name] = merged
    else:
      cfg.profiles[name] = prof
  if ws.governance.blocked.len > 0:
    cfg.governance.blocked.add(ws.governance.blocked)
  if ws.governance.trusted.len > 0:
    cfg.governance.trusted.add(ws.governance.trusted)
  if ws.governance.minimumReleaseAgeHours > 0 and
      cfg.governance.minimumReleaseAgeHours == 0:
    cfg.governance.minimumReleaseAgeHours = ws.governance.minimumReleaseAgeHours
  resolveCatalogDeps(cfg)

proc applyPatches*(cfg: var BauConfig) =
  ## Apply root-level dependency patches over normal dependency entries.
  for name, patch in cfg.patches.pairs:
    cfg.deps[name] = patch
  resolveCatalogDeps(cfg)

proc resolveProfile*(profiles: Table[string, ProfileInfo];
    name: string): ProfileInfo =
  ## Resolve a profile by name, including any inherited parent profile.
  if not profiles.hasKey(name):
    raise newException(ValueError, "unknown profile: " & name)
  result = profiles[name]
  if result.extends.len > 0:
    let parent = resolveProfile(profiles, result.extends)
    result = parent
    mergeProfile(result, profiles[name])

proc loadGlobalConfig*(): Option[FullConfig] =
  ## Load optional user-level Bau config from the platform config directory.
  ##
  ## Invalid global config is ignored so local project commands remain usable.
  let path = globalConfigPath()
  if not fileExists(path):
    return none(FullConfig)
  try:
    var cfg = FullConfig()
    let root = parsetoml.parseFile(path)
    if root.hasKey("profile"):
      cfg.globalProfile = some(parseProfileInfo(root["profile"]))
    if root.hasKey("tasks"):
      for item in root["tasks"].getElems():
        cfg.globalTasks.add(parseTaskInfo(item))
    result = some(cfg)
  except:
    result = none(FullConfig)

proc loadLocalConfig*(projectDir: string): Option[BauConfig] =
  ## Load an optional `bau.local.toml` override for a project.
  ##
  ## Invalid local config is ignored by design.
  let path = projectDir / LocalConfigFileName
  if not fileExists(path):
    return none(BauConfig)
  try:
    result = some(parseBauConfigFile(path))
  except:
    result = none(BauConfig)

proc loadWorkspaceConfig*(path: string): Option[WorkspaceConfig] =
  ## Load a workspace table from a config file, if one exists.
  ##
  ## Invalid workspace config returns `none`.
  if not fileExists(path):
    return none(WorkspaceConfig)
  try:
    let root = parsetoml.parseFile(path)
    if root.hasKey("workspace"):
      result = some(parseWorkspaceConfig(root["workspace"]))
  except:
    result = none(WorkspaceConfig)

proc mergeBauConfig*(base: var BauConfig; override: BauConfig) =
  ## Merge an override configuration into `base`.
  ##
  ## This is used for local and layered config where populated override values
  ## should replace or extend the already-loaded project configuration.
  if override.package.name.len > 0:
    base.package = override.package
  else:
    if override.package.version.len > 0:
      base.package.version = override.package.version
    if override.package.description.len > 0:
      base.package.description = override.package.description
    if override.package.authors.len > 0:
      base.package.authors = override.package.authors
    if override.package.license.len > 0:
      base.package.license = override.package.license
    if override.package.edition.len > 0:
      base.package.edition = override.package.edition
    if override.package.repository.len > 0:
      base.package.repository = override.package.repository
    if override.package.homepage.len > 0:
      base.package.homepage = override.package.homepage
    if override.package.includeFiles.len > 0:
      base.package.includeFiles = override.package.includeFiles
    if override.package.excludeFiles.len > 0:
      base.package.excludeFiles = override.package.excludeFiles
  if override.build.kind != base.build.kind or override.build.name.len > 0 or
      override.build.source.len > 0 or override.build.main.len > 0 or
      override.build.output.len > 0 or override.build.nim.len > 0 or
      override.build.backend.len > 0 or override.build.includeDefault:
    if override.build.name.len > 0:
      base.build.name = override.build.name
    if override.build.source.len > 0:
      base.build.source = override.build.source
    if override.build.main.len > 0:
      base.build.main = override.build.main
    if override.build.output.len > 0:
      base.build.output = override.build.output
    if override.build.nim.len > 0:
      base.build.nim = override.build.nim
    if override.build.backend.len > 0:
      base.build.backend = override.build.backend
    if override.build.includeDefault:
      base.build.includeDefault = true
    base.build.kind = override.build.kind
  if override.toolchain.nim.len > 0:
    base.toolchain.nim = override.toolchain.nim
  if override.toolchain.atlas.len > 0:
    base.toolchain.atlas = override.toolchain.atlas
  if override.governance.blocked.len > 0:
    base.governance.blocked = override.governance.blocked
  if override.governance.trusted.len > 0:
    base.governance.trusted = override.governance.trusted
  if override.governance.minimumReleaseAgeHours > 0:
    base.governance.minimumReleaseAgeHours =
      override.governance.minimumReleaseAgeHours
  if override.cache.dir.len > 0:
    base.cache.dir = override.cache.dir
  if override.cache.remote.len > 0:
    base.cache.remote = override.cache.remote
  base.cache.read = override.cache.read
  base.cache.write = override.cache.write
  if override.install.dir.len > 0:
    base.install.dir = override.install.dir
  if override.docs.configured:
    base.docs = override.docs
  if override.test.configured:
    base.test = override.test
  for key, pval in override.profiles.pairs:
    if base.profiles.hasKey(key):
      mergeProfile(base.profiles[key], pval)
    else:
      base.profiles[key] = pval
  for t in override.targets:
    var found = false
    for i in 0..<base.targets.len:
      if base.targets[i].name == t.name:
        base.targets[i] = t
        found = true
        break
    if not found:
      base.targets.add(t)
  for key, dval in override.deps.pairs:
    base.deps[key] = dval
  for key, pval in override.patches.pairs:
    base.patches[key] = pval
  for key, source in override.sources.pairs:
    base.sources[key] = source
  for key, fval in override.features.pairs:
    base.features[key] = fval
  for key, alias in override.aliases.pairs:
    base.aliases[key] = alias
  for key, catalog in override.catalogs.pairs:
    base.catalogs[key] = catalog
  for t in override.buildScripts:
    base.buildScripts.add(t)
  for t in override.tasks:
    base.tasks.add(t)
  resolveCatalogDeps(base)

proc loadEffectiveConfig*(projectDir: string;
    workspaceRoot: string = ""): BauConfig =
  ## Load the project config after workspace, local, global, and env overrides.
  let mainPath = projectDir / ConfigFileName
  result = parseBauConfigFile(mainPath)

  if workspaceRoot.len > 0 and workspaceRoot != projectDir:
    let wsCfg = loadWorkspaceConfig(workspaceRoot / ConfigFileName)
    if isSome(wsCfg):
      applyWorkspaceDefaults(result, get(wsCfg))
    try:
      let rootCfg = parseBauConfigFile(workspaceRoot / ConfigFileName)
      result.patches = rootCfg.patches
    except CatchableError:
      discard

  let localOverride = loadLocalConfig(projectDir)
  if isSome(localOverride):
    mergeBauConfig(result, get(localOverride))

  let globalCfg = loadGlobalConfig()
  if isSome(globalCfg) and isSome(get(globalCfg).globalProfile):
    if not result.profiles.hasKey("dev"):
      result.profiles["dev"] = get(get(globalCfg).globalProfile)
    else:
      mergeProfile(result.profiles["dev"], get(get(globalCfg).globalProfile))
    for t in get(globalCfg).globalTasks:
      result.tasks.add(t)

  for key, val in envPairs():
    if key.startsWith("BAU_"):
      let cleanKey = key[5..^1].toLowerAscii()
      case cleanKey
      of "profile":
        discard
      of "flags":
        let flags = val.split(",")
        if not result.profiles.hasKey("dev"):
          result.profiles["dev"] = initProfileInfo()
        result.profiles["dev"].flags.add(flags)
      of "gc":
        if not result.profiles.hasKey("dev"):
          result.profiles["dev"] = initProfileInfo()
        result.profiles["dev"].gc = val
      else:
        discard

  applyPatches(result)
