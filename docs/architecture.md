# Bau Architecture

Bau is a reproducible build system for Nim. Its architecture is organized around a small set of durable boundaries: declared intent, resolved state, generated outputs, shared operations, and command surfaces.

For canonical terminology, see [../CONTEXT.md](../CONTEXT.md). Architecture decisions with durable trade-offs live in [adr/](adr/).

## Architectural Shape

Bau separates the user's declared intent from the state and outputs that Bau derives from it:

```text
Project Manifest
      |
      v
Resolved State
      |
      v
Bau Outputs
```

- The **Project Manifest** is the user-authored declaration of a **Bau Project**.
- **Resolved State** records decisions Bau has made from that declaration, such as dependency resolution.
- **Bau Outputs** are generated files or reports produced by Bau operations.

This split is important because a stale resolved state is not the same thing as an invalid manifest. Bau should report staleness precisely instead of blurring declared intent and recorded outcomes.

Project-local state has three broad categories:

- Source intent: project source files and the Project Manifest.
- Generated project state: Dependency Material, Dependency Lock, and Bau Outputs.
- External tools and services: Nim, Atlas, registries, networks, and remote cache services.

## Implementation Map

The architecture is implemented across focused modules:

- **Project Manifest** parsing and merging: `src/bau/config.nim`
- **Operations**: `src/bau/ops.nim`
- **Command Surfaces**: `src/bau/command.nim`, `src/bau/mcp.nim`
- **Targets**, **Profiles**, and **Features**: `src/bau/build.nim`, `src/bau/features.nim`
- **Dependency Material**, **Dependency Lock**, **Dependency Sources**, and dependency policy: `src/bau/atlas.nim`, `src/bau/lock.nim`, `src/bau/depscheck.nim`
- **Tasks** and **Task Cache Entries**: `src/bau/taskgraph.nim`, `src/bau/taskcache.nim`
- **Target Fingerprints**: `src/bau/fingerprint.nim`
- **Workspaces** and **Workspace Members**: `src/bau/workspace.nim`
- **Build Scripts** and **Lifecycle Hooks**: `src/bau/buildscript.nim`, `src/bau/build.nim`
- **Introspection**: `src/bau/metadata.nim`, `src/bau/affected.nim`, `src/bau/nimscan.nim`
- **Nimble Conversion** and **Target Discovery**: `src/bau/nimble.nim`, `src/bau/tailor.nim`
- **Package Contents** and **Publication**: `src/bau/packaging.nim`, `src/bau/command.nim`

## Command Surfaces And Operations

Bau exposes behavior through multiple **Command Surfaces**, currently including the CLI and MCP. These surfaces should adapt input and output, while **Operations** own behavior.

```text
CLI \
     > Operation -> Project Manifest / Resolved State / Bau Outputs
MCP /
```

The architectural rule is: if the CLI and MCP expose the same capability, they should call the same **Operation**. Different formatting, transport, or interactivity belongs in the command surface, not in duplicated behavior.

Some current CLI paths still call lower-level modules directly. That is implementation drift to converge into shared operations, not a second architecture.

External `bau-*` command delegation is a Command Surface extension point. Its
side effects are defined by the delegated command and are not classified as Bau
Operations unless the extension is explicitly modeled as one.

MCP exposes the non-interactive Bau Operations. Interactive `shell`,
`version`/`help`, and external `bau-*` command delegation remain command-surface
behavior rather than MCP tools.

Watch mode repeats the selected operation when supported. It inherits that
operation's category instead of becoming a separate Operation.

Operations are classified by side effect:

- **Introspection** reads structure, state, or planned work.
- **Validation** checks project state and may fail without intentionally changing it.
- **Execution** performs work and may create or refresh Bau Outputs as the expected result.
- **Mutation** has the primary purpose of editing, removing, or refreshing project state, installed or local state, or external service state.

Producing ordinary Bau Outputs as part of build, run, docs, or task work is
execution. Mutation covers operations whose purpose is to change project state,
installed/local state, external service state, or remove/alter existing files.
When an operation has secondary side effects, classify it by primary purpose and
call out the side effect where it matters. For example, a task execution may
write a remote cache entry, but it remains **Execution** unless cache mutation is
the operation's primary purpose. Reading from a remote task cache is part of Task
Cache Entry restoration; writing to a remote task cache is the secondary
external-service side effect.

A dry-run mode must not mutate project, local, installed, or external service
state. It may perform introspection, validation, planning, and generated preview
output.

### Current Command Classification

| Command | Category | Primary purpose | Notes |
|---|---|---|---|
| `build` | Execution | Compile targets | May create or refresh build outputs |
| `run` | Execution | Execute a target | May build first |
| `test` | Validation | Check the project against a Test Plan | Runs test code, but validates project state |
| `check` | Validation | Run Nim semantic checks | No intentional writes |
| `lint` | Validation | Check style rules | No intentional writes |
| `doc` | Execution | Generate documentation | Writes documentation outputs |
| `task` | Execution by default | Run a workflow step | Inherits category when delegating to a built-in Operation |
| `fmt` | Mutation | Rewrite source formatting | Needs a check-only validation variant |
| `ci` | Validation | Run validation gates | Does not run mutating formatting |
| `deps sync` | Mutation | Materialize dependency material | May refresh resolved state |
| `deps lock` | Mutation | Write dependency lock | Updates Resolved State |
| `deps update` | Mutation | Change dependency material or selected revision | Usually followed by lock/verify |
| `deps verify` | Validation | Check dependency policy and lock health | Evaluates Governance Policy |
| `deps vendor` | Mutation | Copy dependency material to vendor state | Writes project-local generated state |
| `deps patch` | Mutation | Add dependency patch intent | Edits Project Manifest |
| `add` / `remove` | Mutation | Edit dependency requirements | Edits Project Manifest |
| `tree` / `outdated` | Introspection | Report dependency structure or status | `outdated` may query external package status |
| `metadata` / `graph` / `query` | Introspection | Report project structure or dependency reasons | Read-only |
| `affected list` | Introspection | Report selected affected work | Read-only |
| `affected check` / `affected test` | Validation | Validate affected work | Uses affected selection |
| `affected build` | Execution | Build affected work | Uses affected selection |
| `explain` / `cache list` / `cache explain` | Introspection | Explain freshness or cache lookup | Read-only |
| `cache clean` | Mutation | Remove task cache entries | Deletes local task cache state |
| `compile-commands` | Mutation | Write compiler command database | Future read-only planning mode should be separate |
| `package --list` / `package --dry-run` | Validation | Validate package contents | Emits introspective file list |
| `package` | Execution | Generate package manifest output | Does not publish |
| `publish --dry-run` | Validation | Validate possible Publication | Does not change registry state |
| `publish` | Mutation | Submit Publication | Mutates external registry state |
| `install` / `update` / `uninstall` | Mutation | Change local installed artifacts | Not Publication |
| `clean` | Mutation | Remove Bau Outputs | Deletes `build/` |
| `init` / `new` / `convert` / `tailor --write` | Mutation | Create or edit project files | `convert --dry-run` is validation with generated preview output; plain `tailor` is introspection, `tailor --check` is validation, and `tailor --write` is mutation |
| `bump` | Mutation | Change Package version intent | `--dry-run` is validation with preview output |
| `ci-template` | Mutation | Write CI configuration files | Creates or overwrites CI templates |
| `shell` | Execution | Start a shell with Build Environment variables | Does not edit project state |
| `shell-init` | Mutation | Edit local shell startup state | Adds Bau bin directory to shell config |
| `doctor` | Validation | Check toolchain and project health | No intentional writes |
| `env` | Introspection | Report Build Environment | Read-only |
| `version` / `help` | Introspection | Report CLI information | Read-only |

Check, lint, dependency verification, tests, and CI are intended to be validation
operations. Build, run, documentation generation, and ordinary task execution are
execution. A task that delegates to a built-in Operation inherits that
Operation's category: `command = "test"` is **Validation**, `command = "build"`
is **Execution**, and a future task command that wraps mutation would be
**Mutation**. Formatting is **Mutation**
because it rewrites source files. A check-only formatting mode is a validation
variant, not a separate domain concept. `bau ci` stays validation-only by
running non-mutating gates instead of invoking `bau fmt`.
Cleaning is **Mutation** because it intentionally removes Bau Outputs.
Dependency materialization and dependency lock writing are **Mutation**.
Dependency verification is **Validation**.
Package listing and dry-runs validate Package Contents without writing package
outputs. Plain package generation is **Execution** because it writes a Bau
Output, but it is still not Publication. Version bumping is **Mutation** because
it changes Package intent in the Project Manifest. Opening a Bau shell is
**Execution**; shell initialization is **Mutation** because it edits local shell
startup state. CI template generation is **Mutation** because it writes project
files. External `bau-*` command delegation is classified by the delegated
command's own behavior; it is not part of Bau's core Operation taxonomy unless
modeled as a Bau Operation.

## Project Model

A **Bau Project** is the unit Bau can build, test, document, or otherwise operate on. A project may have a **Package**, but a package is only the publishable Nim identity and metadata.

A **Workspace** is a coordination root. It selects and configures **Workspace Members**, and each workspace member is a **Bau Project**. The workspace root is not implicitly a buildable member unless that behavior is made explicit.

## Build Model

Bau builds **Targets** under selected **Profiles** and enabled **Features**.

- A **Target** is the artifact being produced or run.
- A **Profile** is the compilation policy used for that build.
- A **Feature** activates optional capabilities and optional dependency requirements.

Compiler backend is build intent. It can be declared with target/build settings
or profile policy and resolves into the target plan; it is not Build
Environment.

A **Target Fingerprint** records freshness for a target build identity. It answers whether compiling that target again would produce the same artifact. It is separate from task output caching.

## Dependency Model

Dependencies move through three distinct states:

```text
Dependency Requirement -> Dependency Material -> Dependency Lock
```

- A **Dependency Requirement** is declared project intent.
- **Dependency Material** is the local package content available to inspect or build against.
- A **Dependency Lock** records resolved dependency state for reproducibility.

A **Dependency Source** changes where a dependency is fetched from or located without changing its intended package identity. A **Dependency Patch** deliberately replaces dependency content and is therefore treated as local override behavior rather than source selection.

Dependency Material is inside the Bau Project boundary as generated project
state. It is not source intent, and it is not external tool state.

A **Governance Policy** defines whether resolved dependency state is acceptable.
It is evaluated by dependency verification, not by dependency declaration.

A **Version Catalog** is a reusable set of dependency version requirements. It
does not fetch, resolve, or lock packages; it only supplies version requirements
that Dependency Requirements can reference.

## Automation Model

Bau supports three different automation concepts:

- A **Task** is a named workflow step.
- A **Build Script** is a project-scoped pre-compilation workflow that can generate files or emit build directives affecting target compilation.
- A **Lifecycle Hook** is legacy timing behavior retained for compatibility around actual build or install execution.

A **Task Cache Entry** is a reusable stored result for a task invocation and can restore declared outputs. It is not the same mechanism as a **Target Fingerprint**.
Task Cache Entries belong only to Tasks that run project commands through
`cmd`. Tasks that delegate to built-in Operations, such as `command = "test"` or
`command = "build"`, use the delegated Operation's own validation or freshness
behavior instead of task output restoration. The current implementation allows
cacheability for any Task with inputs and outputs; that is implementation drift.
Root Task arguments are part of the Task Cache Entry identity, so two
invocations with different arguments must not restore the same cached outputs.
Execution shape and declared inputs are identity: selected Profile, enabled
Features, platform, Nim version, task environment, declared environment inputs,
declared input content, declared output paths, working directory, shell, command
string, and root Task arguments can all affect what the task produces.
Cache location and read/write settings are policy over cache use, not output
identity, and should not contribute to the Task Cache Entry identity. The
current implementation excludes cache locations but includes `cache-read` and
`cache-write` in Task Cache Entry identity; the latter is implementation drift.
Mtime-based task freshness, where declared outputs are newer than declared
inputs, is a local skip. It is separate from Task Cache Entries because it does
not restore a stored result.
For task execution, `--force` bypasses Task Cache Entry restoration and
mtime-based local freshness for the current run. It does not change the Task
Cache Entry identity, and the rerun may still publish cached outputs when cache
writes are enabled.

A Task is a workflow concept, not a side-effect category. Shell tasks are
ordinary Execution by default. Tasks that delegate to built-in Operations inherit
the delegated Operation category.

Task dependencies form a graph of Tasks. A dependency name must resolve to
another Task, not to a built-in Operation. Workflows that need build or test as a
dependency should declare an explicit wrapper Task with `command = "build"` or
`command = "test"` and depend on that Task. The current implementation falls
back from a missing task dependency to a built-in command named `build` or
`test`; that is implementation drift.

Arguments passed after `bau task <name> --` belong only to the invoked root Task.
They do not flow into dependency Tasks, which should remain stable graph
prerequisites.
Task scripts should prefer the task argument environment interface over command
string substitution. `{args}` and `{argsWithSep}` remain forwarding conveniences
for simple wrapper commands.

Build Scripts communicate with Bau through **Build Directives**: emitted lines
that adjust compilation, track inputs, register generated files, or report
warnings and errors. Because Build Directives are Bau's build-script protocol,
their names and meanings are a public compatibility surface. New directives can
be added, but existing directive names and meanings should change only through
deprecation or an explicit compatibility break. Unknown `bau::` directive names
are invalid and should fail loudly. Malformed directives and directives with
missing required values are also invalid. The current implementation warns for
unknown directive names and silently ignores empty values; that is implementation
drift, not the intended contract.
Build Directives are recognized only from Build Script stdout; stderr is for
human diagnostics. The current implementation captures combined stdout and
stderr, so it may parse diagnostics as directives; that is implementation drift.

Build Scripts are not target-scoped concepts. They belong to the Bau Project,
run under the selected Profile and Features, and their Build Directives are
folded into the Target compilation currently being planned.

Bau may cache Build Script directive results internally while planning target
compilation. That cache is not a Task Cache Entry: it is not user-invoked, does
not restore task outputs, and should not become a glossary concept unless it
becomes user-facing.

Build Script generated files are registered through the `bau::generated-file`
Build Directive. Task-style `outputs` belongs to Tasks and Task Cache Entries,
not to the Build Script contract.
Relative paths in `bau::generated-file` and `bau::rerun-if-changed` are resolved
from the Bau Project root, not from the Build Script process `cwd`.

Build Script environment freshness is registered through
`bau::rerun-if-env-changed`. Task-style `envInputs` belongs to Tasks and Task
Cache Entries, not to the Build Script contract.

Build Scripts should prefer narrow Build Directives such as `bau::define` and
`bau::link-lib` when Bau models the intent. `bau::nim-flag` remains an escape
hatch for compiler options that do not yet have a narrower directive.

Lifecycle Hooks do not contribute to Target Fingerprints and do not run when a
target build is skipped as cached. Anything that generates build inputs, changes
compiler behavior, or needs freshness tracking belongs in a Build Script instead
of a Lifecycle Hook.

Local task cache entries are Bau Outputs. Remote cache entries are external
service state that contains serialized Bau Outputs. Restoring a remote entry is
part of Task Cache Entry restoration; writing one is a secondary side effect of
task execution when cache writes are enabled.

Testing uses a **Test Plan**, not a Task. A task may delegate to testing, but the selected runner, test files, profiles, filters, and execution options belong to the test operation.

## Tooling And Introspection

Bau prepares a **Build Environment** for operations from selected profile, enabled features, tool locations, search paths, and relevant environment variables. This is distinct from **Toolchain Requirements**, which are the external tool versions a project expects. External service configuration such as registry sources and remote cache URLs belongs to the Project Manifest and operation inputs, not the Build Environment.

Toolchain Requirements cover external tools such as Nim and Atlas. Package
libraries remain Dependency Requirements.

**Introspection** operations expose structure, state, or planned work without performing validation or mutation. Metadata, graph, query, affected listing, explain output, cache explanation, and MCP resources belong in this category. Affected commands inherit the side-effect category of the selected work: affected check and affected test are **Validation**, while affected build is **Execution**. Documentation generation is **Execution** because it runs Nim doc and writes Bau Outputs. Current compile-command generation is **Mutation** because it writes `compile_commands.json`; a future read-only planning form should be a distinct mode.

## Migration And Discovery

Bau has two onboarding paths that solve different problems:

- **Nimble Conversion** translates deterministic Nimble metadata and literal automation into a **Project Manifest**.
- **Target Discovery** scans Nim source for undeclared buildable entrypoints and suggests missing **Targets**.

Conversion does not execute dynamic NimScript, and target discovery does not infer package intent. Keeping these concepts separate prevents migration from becoming a guessing engine.

## Publication Boundary

Publication is separate from deployment and from ordinary project operation.

- A **Package** is the publishable identity and metadata.
- **Package Contents** are the selected files prepared for registry-compatible distribution.
- **Publication** submits the package and contents to a registry-compatible channel.

Local-only behavior such as path dependencies and dependency patches blocks real publication because it cannot be reproduced by the registry consumer.

Install, update, and uninstall are local mutation operations over built target
artifacts. They are not Publication.

Package dry-runs are validation with introspective output: they check whether
Package metadata and Package Contents are acceptable without publishing.
Publish dry-runs validate a possible Publication. Real publication mutates
external registry state.
