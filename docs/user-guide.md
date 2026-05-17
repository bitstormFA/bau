# Bau User Guide

Bau is a build system for Nim projects. It uses a declarative **Project
Manifest** (`bau.toml`) to describe a project, records dependency **Resolved
State** in `bau.lock`, and produces **Bau Outputs** such as binaries, docs,
metadata, cache entries, and package manifest outputs.

This guide explains the concepts, commands, and manifest fields you need to use
Bau day to day. For task-oriented recipes, see the [workflow guide](workflow-guide.md).
For canonical project language, see [../CONTEXT.md](../CONTEXT.md). For the
architecture behind these terms, see [architecture.md](architecture.md).

## Contents

1. [Core Model](#core-model)
2. [Install Bau](#install-bau)
3. [Create Or Convert A Project](#create-or-convert-a-project)
4. [Project Manifest](#project-manifest)
5. [Build Model](#build-model)
6. [Dependency Model](#dependency-model)
7. [Automation Model](#automation-model)
8. [Workspaces](#workspaces)
9. [Introspection](#introspection)
10. [Documentation And Publication](#documentation-and-publication)
11. [MCP Server](#mcp-server)
12. [Command Reference](#command-reference)
13. [Project Manifest Reference](#project-manifest-reference)

## Core Model

Bau separates the things a project declares from the things Bau resolves and
generates.

```text
Project Manifest -> Resolved State -> Bau Outputs
```

The **Project Manifest** is `bau.toml`. It is the user-authored intent for a
**Bau Project**: package identity, targets, profiles, features, dependencies,
tasks, docs, cache settings, toolchain requirements, and policy.

**Resolved State** is machine-written state derived from the manifest. The most
important example is the **Dependency Lock** (`bau.lock`), which records the
resolved dependency graph, exact versions or Git revisions, source identity,
checksums, and workspace member metadata.

**Bau Outputs** are generated results: compiled artifacts, docs, metadata,
task cache entries, fingerprints, package manifest outputs, and similar files under
`build/` or configured output directories.

### How Bau differs from Nimble

Nimble combines package metadata with executable NimScript. Bau uses a static
TOML manifest and explicit operations.

| Concern | Nimble | Bau |
|---|---|---|
| Project intent | `.nimble` NimScript | `bau.toml` Project Manifest |
| Build shape | Implicit `bin` / `srcDir` and NimScript | Explicit Targets |
| Compiler settings | NimScript conditionals | Named Profiles |
| Optional capability selection | Manual `-d:` flags | Declared Features |
| Dependency fetching | Nimble behavior | Atlas materialization |
| Dependency reproducibility | No project lock by default | `bau.lock` Dependency Lock |
| Workflow automation | Nimble tasks/hooks | Tasks, Build Scripts, Lifecycle Hooks |
| Tool integration | CLI-oriented | Shared Operations for CLI and MCP |

Bau does not execute the manifest to discover project intent. Dynamic behavior
is modeled explicitly with profiles, features, tasks, and build scripts.

## Install Bau

Prerequisites:

- Nim `>= 2.2`
- `parsetoml`
- Atlas for dependency synchronization

Build Bau from this repository:

```sh
nimble install parsetoml
nim c --path:src -o:build/dev/bau src/bau.nim
```

Move `build/dev/bau` onto your `PATH`, or call it by path until you install it.

Check a project:

```sh
bau doctor
bau env --json
```

`bau doctor` verifies configured toolchain requirements. `bau env --json`
prints the resolved build environment: selected profile, features, paths, tool
locations, and relevant environment variables. External service configuration
such as registry sources and remote cache URLs remains manifest data, not build
environment.

Toolchain requirements are external tools such as Nim and Atlas. Package
libraries such as `parsetoml` are Dependency Requirements, not Toolchain
Requirements.

## Create Or Convert A Project

Create a binary project:

```sh
bau new myapp
cd myapp
bau deps sync
bau check
bau test
bau run
```

Create a library project:

```sh
bau new mylib --lib
cd mylib
bau deps sync
bau test
bau doc --open
```

Initialize the current directory:

```sh
bau init
bau init myapp --bin --version 0.1.0 --description "A Nim app" --license MIT
```

Convert an existing Nimble project:

```sh
bau convert --dry-run
bau convert
bau deps sync
bau tailor --check
bau check --all-targets
bau test
```

**Nimble Conversion** is static. Bau translates deterministic Nimble metadata,
literal tasks, and literal hooks. It does not execute NimScript control flow.

**Target Discovery** is separate:

```sh
bau tailor
bau tailor --check
bau tailor --write
```

`bau tailor` reports undeclared entrypoints, `bau tailor --check` validates that
none are missing, and `bau tailor --write` mutates the Project Manifest by
adding missing target declarations.

## Project Manifest

A minimal manifest:

```toml
[package]
name = "myapp"
version = "0.1.0"
description = "A Nim application"
license = "MIT"
edition = "2026"

[build]
kind = "bin"
source = "src"
main = "src/myapp.nim"
output = "myapp"

[profile.dev]
flags = ["--debugInfo:on"]
gc = "orc"

[profile.release]
flags = ["--opt:speed", "--passC:-O3"]
gc = "orc"
```

The manifest can also declare dependencies, features, targets, tasks, build
scripts, docs, workspaces, cache settings, install defaults, governance policy,
toolchain requirements, sources, patches, catalogs, and aliases.

Bau resolves Project Manifest inputs in this order, with later layers overriding
earlier ones:

1. Global defaults from the Bau config directory.
2. Workspace-level defaults.
3. Project `bau.toml`.
4. Local overrides from `bau.local.toml`.
5. `BAU_` environment settings for selected development defaults.

Use `bau.local.toml` only for local machine preferences. Do not rely on it for
requirements that CI or other developers must share.

## Build Model

Bau builds a **Target** under a **Profile** with selected **Features**.

- A **Target** is the artifact Bau can produce or run.
- A **Profile** is a named compilation policy.
- A **Feature** is a named optional capability that may activate other features
  or optional dependency requirements.

Build examples:

```sh
bau build
bau build cli
bau build --profile release
bau build --features db
bau build --no-default-features --features db
bau build --all-features
bau run -- --help
bau run cli -- --version
```

### Targets

The default target is declared in `[build]`. Additional targets use
`[[targets]]`:

```toml
[[targets]]
name = "admin"
kind = "bin"
main = "src/admin.nim"
profile = "release"
requiredFeatures = ["db"]
```

`requiredFeatures` prevents a target from being built when its feature
preconditions are missing.

### Profiles

Profiles group compiler settings:

```toml
[profile.dev]
flags = ["--debugInfo:on"]
gc = "orc"

[profile.release]
flags = ["--opt:speed", "--passC:-O3"]
gc = "orc"
define = { release = "" }

[profile.test]
extends = "dev"
flags = ["--define:testing"]
```

Profiles can inherit with `extends`. If a requested profile is not defined, Bau
uses an empty profile with normal defaults.

Compiler backend is build intent. It may come from `[build]`, a target, or a
profile override, and it resolves into the target plan rather than the Build
Environment.

### Features

Features resolve transitively:

```toml
[dependencies]
sqlite = { version = ">=3.0", optional = true }
analytics = { git = "https://example.com/analytics", optional = true }

[features]
default = ["cli"]
cli = []
db = ["dep:sqlite"]
analytics = ["dep:analytics", "db"]
```

Each enabled feature emits a namespaced Nim define and a bare define:

```text
-d:bauFeature_db
-d:db
```

Enabled features are also exposed to tasks and build scripts as
`BAU_FEATURE_<NAME>=1`.

### Target Fingerprints

A **Target Fingerprint** records the freshness identity of a target build. It
includes source content, selected manifest/local/global inputs, relevant
environment inputs, compiler flags, profile, platform, and toolchain identity.

A matching fingerprint means Bau expects the same compilation result and can
skip rebuilding the target. Use `bau explain` when a target rebuilds
unexpectedly or stays fresh when you expected it to rebuild.

## Dependency Model

Dependencies have three distinct states:

```text
Dependency Requirement -> Dependency Material -> Dependency Lock
```

- A **Dependency Requirement** is declared in `[dependencies]`.
- **Dependency Material** is local package content fetched or linked by Atlas.
- A **Dependency Lock** is the resolved graph recorded in `bau.lock`.

Bau delegates fetching and package resolution to Atlas, then inspects the
materialized result and writes a reproducible lock.

Dependency Material is generated project state. It lives inside the project
boundary, but it is not source intent.

### Declaring dependencies

Registry dependencies:

```toml
[dependencies]
parsetoml = ">=0.6.0"
jsony = ">=1.1.0"
```

Git dependencies:

```toml
[dependencies]
mylib = { git = "https://github.com/user/mylib", tag = "v2.0.0" }
devtool = { git = "https://github.com/user/devtool", branch = "main" }
pinned = { git = "https://github.com/user/pkg", rev = "abc123def" }
```

Local path dependencies:

```toml
[dependencies]
myutil = { path = "../myutil" }
```

Optional dependencies are activated by features:

```toml
[dependencies]
sqlite = { version = ">=3.0", optional = true }

[features]
db = ["dep:sqlite"]
```

### Sync, lock, and verify

```sh
bau deps sync
bau deps lock
bau deps sync --locked
bau deps sync --offline
bau deps sync --frozen
bau deps verify
```

`--locked` requires `bau.lock` to be present and current. `--offline` avoids
network access and checks local material. `--frozen` is both.

Commit `bau.lock` for applications. For libraries, committing the lock is
recommended when you want contributors and CI to use the same dependency graph.

### Sources and patches

A **Dependency Source** changes where a dependency is fetched from without
changing the intended package identity:

```toml
[source."internal"]
registry = "https://registry.example.com/nimble"

[dependencies]
internal_lib = { version = ">=1.0", registry = "internal" }
```

A **Dependency Patch** replaces dependency content:

```toml
[patch]
parsetoml = { path = "../parsetoml" }
```

Use sources for mirrors or alternate locations. Use patches for local fixes and
experiments. Remove patches and local path dependencies before publication.

### Governance policy

Governance policies are enforced by `bau deps verify`:

```toml
[governance]
blocked = ["badpkg"]
trusted = ["parsetoml", "jsony"]
minimumReleaseAgeHours = 24
```

The **Governance Policy** does not declare dependencies; it decides whether
resolved dependency state is acceptable. `blocked` is a deny-list. `trusted`
becomes an allow-list when non-empty.
`minimumReleaseAgeHours` uses the lock entry's preserved `lockedAt` timestamp
for non-path dependencies.

## Automation Model

Bau has three automation concepts:

- A **Task** is a named workflow step.
- A **Build Script** is a pre-compilation workflow that may generate files or
  emit directives affecting target compilation.
- A **Lifecycle Hook** is legacy timing behavior retained for compatibility
  around actual build or install execution.

Testing uses a **Test Plan**, not a Task. A task may delegate to `bau test`,
but the selected runner, test files, profiles, filters, and execution options
belong to the test operation.

### Tasks

```toml
[[tasks]]
name = "site"
cmd = "nim r tools/site.nim"
inputs = ["docs/**/*.md", "tools/site.nim"]
outputs = ["build/site"]
cache = true
```

Run tasks:

```sh
bau task --list
bau task site
bau task site -- --draft
bau task site --dry-run
bau task site --keep-going
```

Task dependencies run in topological order with cycle detection. When a `cmd`
task declares inputs and outputs, Bau can write a **Task Cache Entry** and
restore outputs later.

Task Cache Entries apply only to tasks that run project commands with `cmd`;
tasks that delegate to built-in operations use those operations' own freshness
or validation behavior.

Root task arguments are part of the Task Cache Entry identity, so different
argument lists restore different cached outputs.
Execution shape and declared inputs are Task Cache Entry identity; cache
transport policy is not.
Cache location and read/write settings do not change that identity; they only
control where and whether Bau may restore or publish cached outputs.
Remote cache reads participate in task output restoration. Remote cache writes
are secondary side effects when cache writes are enabled.
If declared outputs are newer than declared inputs, Bau may skip the task as
locally fresh without restoring a Task Cache Entry.
`bau task <name> --force` bypasses restoration and local freshness for that run
without changing the Task Cache Entry identity.

Shell tasks are ordinary execution by default. A task that delegates to a
built-in operation inherits that operation category, so `command = "test"` is
Validation and `command = "build"` is Execution.

Task dependencies name other tasks only. If a workflow needs build or test as a
dependency, declare an explicit wrapper task with `command = "build"` or
`command = "test"` and depend on that task.

Arguments after `bau task <name> --` are passed only to the invoked root task,
not to dependency tasks.
Prefer `BAU_TASK_ARG_0`, `BAU_TASK_ARG_1`, and `BAU_TASK_ARGS` inside scripts.
Use `{args}` and `{argsWithSep}` only when a task is forwarding arguments to
another command.

Local task cache entries are Bau Outputs. Remote task cache entries are external
service state that Bau can read or write.

Build-script directive caching is internal target-planning state. It is separate
from Task Cache Entries and does not restore task outputs.

Inspect task caching:

```sh
bau cache list
bau cache explain site
bau cache explain site --json
bau cache clean
```

### Build scripts

Build scripts are project-scoped workflows that run before target compilation:

```toml
[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
```

They can print **Build Directives**:

```text
bau::rerun-if-changed=path
bau::rerun-if-env-changed=NAME
bau::define=name=value
bau::link-lib=sqlite3
bau::nim-flag=--passC:-DUSE_X
bau::generated-file=src/generated/version.nim
bau::warning=message
bau::error=message
```

Prefer narrow directives such as `bau::define` and `bau::link-lib` when they
match the intent. Use `bau::nim-flag` as an escape hatch for compiler options
Bau does not model yet.

Write Build Directives to stdout. Use stderr for human diagnostics.

Unknown `bau::` directive names are invalid. Bau should fail loudly rather than
silently ignore a misspelled build instruction. Supported directive names and
meanings are part of Bau's public build-script contract.
Malformed directives and directives with missing required values are invalid.

Generated files are registered with `bau::generated-file`; task-style `outputs`
belongs to cached Tasks, not Build Scripts.
Environment freshness is registered with `bau::rerun-if-env-changed`;
task-style `envInputs` belongs to cached Tasks, not Build Scripts.
Relative paths in Build Directives are resolved from the Bau Project root, not
from the script process `cwd`.

Use build scripts for new build-influencing behavior. Lifecycle hooks exist for
Nimble compatibility.

## Workspaces

A **Workspace** is a coordination root. It selects and configures
**Workspace Members**, and each member is a **Bau Project**.

```toml
[workspace]
members = ["pkg/core", "pkg/utils", "apps/cli"]
defaultMembers = ["apps/cli"]
exclude = ["pkg/deprecated"]

[workspace.catalog]
jsony = ">=1.1.0"
parsetoml = ">=0.6.0"
```

Workspace defaults can include dependencies, sources, profiles, catalogs, and
governance. Member projects keep their own manifests and can override shared
defaults.

The workspace root uses one root `bau.lock` for the selected member graph. Bau
reuses the selected member set for build, dependency sync/verify, metadata,
graph/query output, affected checks, compile command generation, docs, and
tailor.

## Introspection

**Introspection** operations expose project structure, state, or planned work
without performing validation, execution, or mutation.

```sh
bau metadata --json
bau graph --format dot
bau graph --format json
bau query deps <target>
bau query why <dependency>
bau affected list --since origin/main --json
bau explain
bau cache explain <task> --json
bau env --json
```

`bau affected` uses Git changes plus Nim module scanning to classify affected
targets, tests, and tasks. Conservative inputs such as `bau.toml`, `bau.lock`,
`deps/**`, and `vendor/**` mark broad work as affected.

`bau affected list` is introspection. `bau affected check` and
`bau affected test` are validation. `bau affected build` is execution.

`bau doc` is not introspection; it is execution because it runs Nim doc and
writes documentation outputs.

`bau compile-commands` is not introspection in its current form; it is mutation
because it writes `compile_commands.json`.

## Documentation And Publication

Generate Nim API documentation through Bau so profiles, features, search paths,
and docs settings are applied:

```sh
bau doc
bau doc --open
bau doc --out-dir site/api
bau doc --skip-examples
bau doc --include-private
bau doc --no-index
```

Publication has three concepts:

- **Package**: publishable Nim identity and metadata.
- **Package Contents**: selected files prepared for distribution.
- **Publication**: submitting the package and contents to a registry-compatible
  channel.

Inspect package contents:

```sh
bau package --list --dry-run
```

This is validation with introspective output: it can fail if Package metadata or
Package Contents are not acceptable.

Prepare publication:

```sh
bau bump --patch
bau deps sync --locked
bau deps verify
bau check --all-targets
bau test
bau doc
bau publish --dry-run
```

A real `bau publish` uses Nimble-compatible metadata and rejects local path
dependencies and `[patch]` entries.
`bau publish --dry-run` is validation. Real `bau publish` mutates external
registry state.

Install, update, and uninstall are local mutation operations over built target
artifacts. They are not Publication.

## MCP Server

Bau includes an MCP server for compatible AI tools:

```sh
bau mcp
# or:
bau --mcp
```

The MCP server speaks JSON-RPC over standard input/output. It exposes Bau
operations as tools and read-only resources. The important architectural rule is
that MCP and CLI command surfaces should share the same **Operations**.

To register the server and add a local Bau skill for a project, run:

```sh
bau mcp setup --all
```

Because agent hosts do not share one MCP registration file, setup can target
specific hosts:

```sh
bau mcp setup --codex
bau mcp setup --claude
bau mcp setup --copilot
```

Setup writes project-local files:

| Host | MCP config | Skill |
|---|---|---|
| Codex | `.codex/config.toml` | `.agents/skills/bau/SKILL.md` |
| Claude Code | `.mcp.json` | `.claude/skills/bau/SKILL.md` |
| GitHub Copilot | `.vscode/mcp.json` | `.github/skills/bau/SKILL.md` |

Existing divergent `bau` entries or skill files are skipped unless `--force` is
provided. Use `--dry-run` to preview file changes.

Common MCP tools:

| Area | Tools |
|---|---|
| Build and validation | `bau_build`, `bau_run`, `bau_test`, `bau_check`, `bau_lint`, `bau_ci`, `bau_doc`, `bau_clean`, `bau_install` |
| Dependencies | `bau_deps`, `bau_add`, `bau_remove`, `bau_deps_verify`, `bau_tree`, `bau_outdated` |
| Tasks and cache | `bau_task`, `bau_cache`, `bau_cache_explain` |
| Introspection | `bau_metadata`, `bau_graph`, `bau_query`, `bau_affected`, `bau_explain`, `bau_env`, `bau_doctor` |
| Project and publication | `bau_init`, `bau_new`, `bau_convert`, `bau_tailor`, `bau_package`, `bau_publish`, `bau_bump` |
| Mutation | `bau_fmt`, `bau_compile_commands`, `bau_ci_template`, `bau_shell_init`, `bau_mcp_setup` |

Read-only resources include:

```text
bau://manifest
bau://targets
bau://deps
bau://tasks
bau://status
```

Example MCP configuration shape:

```json
{
  "mcpServers": {
    "bau": {
      "command": "bau",
      "args": ["mcp"]
    }
  }
}
```

## Command Reference

For side-effect categories, see
[Current Command Classification](architecture.md#current-command-classification).

### Core commands

| Command | Purpose |
|---|---|
| `bau build [target]` | Compile the default target or a named target |
| `bau run [target] [-- args]` | Build and run a binary target |
| `bau test [filter]` | Validate the project against a Test Plan |
| `bau check` | Validate configured targets with `nim check` |
| `bau doc` | Generate API documentation |
| `bau clean` | Remove Bau Outputs under `build/` |
| `bau fmt` | Rewrite Nim source files with `nimpretty` |
| `bau lint` | Validate style rules |
| `bau ci` | Run the validation sequence without rewriting source files |

The intended validation counterpart to `bau fmt` is a future check-only
formatting mode, such as `bau fmt --check`.

### Dependency commands

| Command | Purpose |
|---|---|
| `bau deps [sync]` | Materialize enabled dependencies with Atlas |
| `bau deps lock` | Write `bau.lock` from materialized dependency state |
| `bau deps update [dep]` | Update dependencies |
| `bau deps update <dep> --precise <rev>` | Pin a materialized Git dependency to an exact revision |
| `bau deps verify` | Verify lock freshness, checksums, and governance policy |
| `bau deps vendor` | Copy dependency material to `vendor/` with checksums |
| `bau deps patch <dep> --path <path>` | Add a local dependency patch |
| `bau add <dep>` | Add a dependency requirement to the manifest |
| `bau remove <dep>` | Remove a dependency requirement |
| `bau tree` | Print the dependency tree |
| `bau outdated` | Show outdated dependencies |

Dependency sync, lock, update, vendor, patch, add, and remove operations are
mutation. Dependency verification is validation. Dependency tree, outdated
status, and query output are introspection.

### Introspection and automation commands

| Command | Purpose |
|---|---|
| `bau metadata --json` | Print project metadata |
| `bau graph --format dot|json` | Print the task, target, feature, and dependency graph |
| `bau query deps <name>` | List dependencies for a target, task, or package |
| `bau query why <dep>` | Explain why a dependency is present |
| `bau affected [list|build|test|check]` | Inspect or run affected work |
| `bau explain` | Explain target freshness differences |
| `bau cache [list|clean|explain]` | Inspect or clean task cache entries |
| `bau task [--list|<name>]` | List or run tasks |
| `bau compile-commands` | Generate `compile_commands.json` |
| `bau env --json` | Print the resolved build environment |
| `bau ci-template github|gitlab` | Write CI template files |
| `bau mcp setup [--all|--codex|--claude|--copilot]` | Write agent MCP and skill setup files |

### Project and publication commands

| Command | Purpose |
|---|---|
| `bau init [name]` | Initialize the current directory |
| `bau new <path>` | Create a new project |
| `bau convert [path|file]` | Convert a Nimble project |
| `bau tailor --check|--write` | Discover missing target declarations |
| `bau package --list` | Validate and list package contents |
| `bau package` | Generate package manifest output |
| `bau bump --major|--minor|--patch` | Increment package version |
| `bau publish` | Publish through Nimble-compatible metadata |
| `bau install [target]` | Copy a built target artifact into an install directory |
| `bau update [target]` | Replace an installed target artifact |
| `bau uninstall [target]` | Remove an installed target artifact |
| `bau shell` | Open a shell with Bau build environment variables |
| `bau shell-init [shell]` | Add `~/.bau/bin` to shell startup files |
| `bau doctor` | Check toolchain and project health |
| `bau version` | Print Bau version |
| `bau help` | Print CLI help |

External `bau-*` commands are command-surface extensions. Their side effects are
defined by the delegated command, not by Bau's core Operation categories.

### Common options

| Option | Purpose |
|---|---|
| `--profile`, `-p <name>` | Select build profile |
| `--jobs`, `-j <n>` | Set parallel build jobs |
| `--verbose`, `-v` | Print nested command details |
| `--quiet`, `-q` | Suppress nonessential Bau output |
| `--watch`, `-w` | Watch and rerun where supported |
| `--timings` | Show timing information |
| `--color auto|always|never` | Control colored output |
| `--force`, `-f` | Force overwrite or bypass cached state where supported |
| `--dry-run`, `-n` | Plan without writing or executing where supported |
| `--all-targets` | Operate on all configured targets where supported |
| `--features <a,b>` | Enable feature flags |
| `--all-features` | Enable every declared feature except `default` |
| `--no-default-features` | Disable default features |
| `--locked` | Require a current lockfile |
| `--offline` | Avoid dependency network operations |
| `--frozen` | Equivalent to `--locked --offline` |
| `--since <git-ref>` | Select Git comparison point for affected work |
| `--json` | Print JSON where supported |
| `--format <mode>` | Select text, dot, or JSON output where supported |

`--watch` repeats the selected operation when supported and inherits that
operation's side-effect category.

## Project Manifest Reference

### `[package]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Publishable package name and default output name |
| `version` | string | Package version |
| `description` | string | Package summary |
| `authors` | string[] | Package authors |
| `license` | string | License identifier |
| `edition` | string | Bau manifest edition |
| `repository` | string | Source repository URL |
| `homepage` | string | Project homepage URL |
| `include` | string[] | Extra package file patterns to include |
| `exclude` | string[] | Package file patterns to exclude |

### `[build]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Optional CLI name for the default target |
| `kind` | string | `bin`, `lib`, or `test` |
| `source` | string | Source directory, default `src` |
| `main` | string | Main Nim source file |
| `output` | string | Output artifact name |
| `nim` | string | Explicit Nim compiler command |
| `backend` | string | Compiler backend such as `c`, `cpp`, or `js` |
| `includeDefault` | bool | Include the default build when explicit targets exist |

### `[[targets]]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Target name |
| `kind` | string | `bin`, `lib`, or `test` |
| `main` | string | Entry point file |
| `output` | string | Output artifact name |
| `source` | string | Source root override |
| `paths` | string[] | Extra Nim import paths |
| `profile` | string | Target-specific profile |
| `requiredFeatures` | string[] | Required enabled features |
| `tags` | string[] | Labels used by commands such as affected analysis |

### `[profile.<name>]`

| Field | Type | Description |
|---|---|---|
| `extends` | string | Parent profile |
| `flags` | string[] | Nim compiler flags |
| `gc` | string | Memory management strategy |
| `define` | table | Nim defines converted to `-d:` flags |
| `backend` | string | Profile-specific backend override |

### `[dependencies]`

Each key is a dependency name. A value may be a version string or an inline
table.

| Field | Type | Description |
|---|---|---|
| `version` | string | Version requirement |
| `git` | string | Git repository URL |
| `tag` | string | Git tag |
| `branch` | string | Git branch |
| `rev` | string | Exact Git revision |
| `path` | string | Local dependency path |
| `registry` | string | Named dependency source |
| `optional` | bool | Enabled only by features |

### `[features]`

| Field | Type | Description |
|---|---|---|
| `default` | string[] | Features enabled unless `--no-default-features` is used |
| `<name>` | string[] | Features, bare dependency names, or `dep:<name>` entries enabled by this feature |

### `[[tasks]]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Task name |
| `cmd` | string | Shell command, URL, or NimScript path |
| `command` | string | Built-in Bau operation such as `build` or `test` |
| `description` | string | Human-readable summary |
| `deps` | string[] | Prerequisite task names |
| `inputs` | string[] | Input file patterns |
| `outputs` | string[] | Produced output paths for cached `cmd` tasks |
| `cwd` | string | Working directory |
| `env` | table | Environment variables set for the task |
| `envInputs` | string[] | Environment variables included in Task Cache Entry identity |
| `watch` | string[] | Paths watched by long-running workflows |
| `shell` | string | Shell override |
| `profile` | string | Profile for built-in task commands |
| `cache` | bool | Force-enable task caching |
| `acceptArgs` | bool | Expose root-task arguments after `--` |
| `requiredFeatures` | string[] | Required enabled features |
| `tags` | string[] | Labels |

### `[[buildScripts]]`

Build scripts use a smaller command shape than tasks: `name`, `cmd`, `inputs`,
`cwd`, `env`, `shell`, `requiredFeatures`, and `tags`. Use
`bau::generated-file` to register generated files and
`bau::rerun-if-env-changed` to register environment inputs. Build Directives are
read from stdout; stderr is for human diagnostics. Malformed directives and
directives with missing required values are invalid. Relative paths in Build
Directives are resolved from the Bau Project root. Prefer narrow directives over
`bau::nim-flag` when Bau models the intent.

### `[scripts]`

Legacy lifecycle hooks:

| Field | Type | Description |
|---|---|---|
| `preBuild` | string | Command run before compilation |
| `postBuild` | string | Command run after compilation |
| `postInstall` | string | Command run after install |

Lifecycle hooks do not participate in target freshness. Use Build Scripts for
generation, compiler flags, generated files, or tracked build inputs.

### `[test]`

| Field | Type | Description |
|---|---|---|
| `runner` | string | Explicit test runner |
| `profiles` | string[] | Profiles included in the Test Plan matrix |
| `defaultProfile` | string | Local default test profile |
| `fullProfiles` | string[] | Full matrix for `bau test --full` and CI |
| `recursive` | bool | Recursively discover `tests/t*.nim` |
| `exclude` | string[] | Tests to skip |
| `showOutput` | string | `auto`, `always`, or `never` |

### `[docs]`

| Field | Type | Description |
|---|---|---|
| `outDir` | string | Documentation output directory |
| `docRoot` | string | Nim doc root setting |
| `entrypoints` | string[] | Documentation entrypoint files |
| `include` | string[] | Additional source patterns |
| `exclude` | string[] | Source patterns to skip |
| `flags` | string[] | Extra Nim doc flags |
| `project` | bool | Use Nim doc project mode |
| `index` | bool | Generate Bau docs index |
| `runExamples` | bool | Compile runnable examples |
| `includePrivate` | bool | Include private symbols |
| `sourceUrl` | string | Source-link URL template |

### `[cache]`

| Field | Type | Description |
|---|---|---|
| `dir` | string | Local cache directory without changing task cache identity |
| `remote` | string | Remote cache URL or path without changing task cache identity |
| `read` | bool | Allow cache reads without changing task cache identity |
| `write` | bool | Allow cache writes without changing task cache identity |

### `[install]`

| Field | Type | Description |
|---|---|---|
| `dir` | string | Install/update/uninstall destination |

When unset, Bau uses `~/.bau/bin`.

### `[toolchain]`

| Field | Type | Description |
|---|---|---|
| `nim` | string | Nim version requirement |
| `atlas` | string | Atlas version requirement |

### `[governance]`

| Field | Type | Description |
|---|---|---|
| `blocked` | string[] | Forbidden dependency names |
| `trusted` | string[] | Allowed dependency names when non-empty |
| `minimumReleaseAgeHours` | int | Minimum age for resolved non-path packages |

### `[source.<name>]`

| Field | Type | Description |
|---|---|---|
| `registry` | string | Registry URL or registry name |
| `directory` | string | Vendor directory |
| `localRegistry` | string | Local registry mirror |
| `git` | string | Git source |
| `replaceWith` | string | Another source name to resolve through |

### `[patch]`

Each key is a dependency name. Values use the same shape as dependency inline
tables.

```toml
[patch]
parsetoml = { path = "../parsetoml" }
```

### `[catalog]`, `[catalogs.<name>]`, and workspace catalogs

Catalogs centralize dependency versions:

```toml
[catalog]
parsetoml = ">=0.6.0"

[catalogs.stable]
jsony = "1.1.0"
```

Reference catalog versions with:

```toml
[dependencies]
parsetoml = "catalog:"
jsony = "catalog:stable"
```

Workspaces can also define `[workspace.catalog]` and
`[workspace.catalogs.<name>]`.

A **Version Catalog** supplies a reusable version requirement. It is not a
Dependency Source and it is not a Dependency Lock.

### `[workspace]`

| Field | Type | Description |
|---|---|---|
| `members` | string[] | Member project paths or patterns |
| `defaultMembers` | string[] | Selected members for default workspace operations |
| `exclude` | string[] | Member paths or patterns to ignore |

Workspace roots may also define shared `package`, `dependencies`, `source`,
`profile`, `catalog`, and `governance` defaults for members.

### `[aliases]`

Aliases expand before command parsing:

```toml
[aliases]
lint-all = "task lint"
release-check = "test --full"
```
