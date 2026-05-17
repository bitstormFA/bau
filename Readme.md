# Bau

Bau is a modern build tool for Nim projects: one declarative project manifest,
explicit build targets, reproducible dependencies, cached workflows, and the
same operations available from the CLI or AI tools through MCP.

It is short for Baumeister, and its job is to make a Nim project easier to
understand, repeat, automate, and publish.

## Why Bau Instead Of Nimble?

Nimble is primarily a package manager with build behavior embedded in NimScript.
Bau keeps the build model explicit:

- **Declarative project manifest**: `bau.toml` describes package metadata,
  targets, profiles, features, dependencies, tasks, docs, cache, toolchain, and
  policy without executing project code to discover intent.
- **Reproducible dependency state**: Bau delegates fetching to Atlas, then
  records the resolved graph, source identity, exact revisions, and checksums in
  `bau.lock`.
- **Explicit build shape**: build a named **Target**, under a named **Profile**,
  with selected **Features**. No more hidden conditionals deciding what a build
  means.
- **Incremental work that is inspectable**: target fingerprints explain whether
  compilation is fresh, while task cache entries can restore declared workflow
  outputs locally or from a shared cache.
- **Build scripts without manifest magic**: pre-compilation scripts can generate
  files and emit `bau::` directives, but the project manifest stays static and
  reviewable.
- **Workspace support**: a workspace root coordinates member projects, shared
  defaults, catalogs, governance, and one dependency lock.
- **Tool-friendly operations**: the CLI and MCP server are command surfaces over
  the same Bau operations, so humans and coding agents can run the same build,
  dependency, metadata, graph, affected, and cache workflows.
- **Reviewable Nimble conversion**: `bau convert` statically translates
  deterministic Nimble metadata and literal automation; `bau tailor` separately
  discovers missing executable targets from source.

## Install From Source

Prerequisites:

- Nim `>= 2.2`
- `parsetoml`
- Atlas when syncing dependencies

Build Bau from this repository:

```sh
nimble install parsetoml
nim c --path:src -o:build/dev/bau src/bau.nim
```

Then call `build/dev/bau`, move it onto your `PATH`, or install it with your
usual local tool setup.

## Quick Start

Create a new binary project:

```sh
bau new myapp
cd myapp
bau deps sync
bau check
bau test
bau run
```

Create a library:

```sh
bau new mylib --lib
cd mylib
bau deps sync
bau test
bau doc --open
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

If `bau tailor --check` reports missing executable targets:

```sh
bau tailor --write
bau check --all-targets
```

## A Small `bau.toml`

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

[dependencies]
parsetoml = ">=0.6.0"
```

The manifest is the project intent. `bau.lock` records resolved dependency
state. `build/` contains generated outputs such as binaries, fingerprints, task
cache entries, docs, and package manifest outputs.

## Everyday Commands

```sh
bau build
bau build --profile release
bau build --features db
bau run -- --help
bau test
bau test --full
bau check --all-targets
bau doc --open
bau fmt
bau lint
bau ci
```

Dependency work:

```sh
bau add jsony --version ">=1.1.0"
bau deps sync
bau deps lock
bau deps sync --locked
bau deps sync --frozen
bau deps verify
bau deps update
bau query why jsony
```

Introspection and automation:

```sh
bau metadata --json
bau graph --format json
bau affected list --since origin/main --json
bau affected test --since origin/main
bau explain
bau cache explain docs --json
bau compile-commands --profile release --features db
```

Publication:

```sh
bau bump --patch
bau package --list --dry-run
bau publish --dry-run
```

## Features And Optional Dependencies

Features activate optional capabilities and optional dependencies:

```toml
[dependencies]
sqlite = { version = ">=3.0", optional = true }

[features]
default = ["cli"]
cli = []
db = ["dep:sqlite"]
```

Use them from the CLI:

```sh
bau build --features db
bau test --features db
bau build --no-default-features --features db
bau build --all-features
```

Enabled features become Nim defines, including a namespaced form such as
`-d:bauFeature_db`.

## Cached Tasks

Tasks are named workflow steps. When a task declares inputs and outputs, Bau can
cache and restore the outputs:

```toml
[[tasks]]
name = "site"
cmd = "nim r tools/site.nim"
inputs = ["docs/**/*.md", "tools/site.nim"]
outputs = ["build/site"]
cache = true
```

```sh
bau task site
bau cache explain site
bau cache explain site --json
```

Target compilation uses fingerprints; task output reuse uses task cache
entries. Bau keeps those mechanisms separate so cache explanations stay honest.

Task cache entries restore outputs only for tasks that run project commands with
`cmd`; tasks that delegate to built-in operations use those operations' own
freshness or validation behavior.

Root task arguments are part of the task cache identity, so different argument
lists restore different cached outputs.
Execution shape and declared inputs are task cache identity; cache transport
policy is not.
Cache location and read/write settings do not change that identity; they only
control where and whether Bau may restore or publish cached outputs.
Remote cache reads participate in task output restoration. Remote cache writes
are secondary side effects when cache writes are enabled.
If declared outputs are newer than declared inputs, Bau may skip the task as
locally fresh without restoring a Task Cache Entry.
`bau task <name> --force` bypasses restoration and local freshness for that run
without changing the task cache identity.

Build-script directive caching is internal target-planning state, not a task
cache entry.

Shell tasks are ordinary execution by default. A task that delegates to a
built-in operation inherits that operation category, so `command = "test"` is
validation and `command = "build"` is execution.

Task dependencies name other tasks only; wrap built-in operations in explicit
tasks before depending on them.

Arguments after `bau task <name> --` are passed only to the invoked root task,
not to dependency tasks. Prefer `BAU_TASK_ARG_0`, `BAU_TASK_ARG_1`, and
`BAU_TASK_ARGS` inside scripts; use `{args}` and `{argsWithSep}` only to forward
arguments to another command.

## Build Scripts

Build scripts are project-scoped workflows that run before target compilation
and can emit `bau::` directives:

```toml
[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
```

Supported directives include:

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

Use build scripts for new build-influencing generation. Legacy lifecycle hooks
exist for Nimble compatibility around actual build or install execution; they do
not participate in target freshness.

## Workspaces

A workspace is a coordination root for member Bau projects:

```toml
[workspace]
members = ["pkg/core", "pkg/utils", "apps/cli"]
defaultMembers = ["apps/cli"]
exclude = ["pkg/deprecated"]

[workspace.catalog]
jsony = ">=1.1.0"
parsetoml = ">=0.6.0"
```

The root can provide shared dependency versions, sources, profiles, catalogs,
and governance. Each member keeps its own project manifest.

## MCP For AI Tools

Bau includes an MCP server:

```sh
bau mcp
```

It exposes the non-interactive Bau operations to compatible tools: build, run,
test, check, lint, CI, docs, dependencies, tasks, cache, metadata, graph, query,
affected work, package/publication preflights, and project setup. The important
bit: MCP calls use the same Bau operations as the CLI, so tool automation is not
a separate build path.

## Documentation

- [Concept glossary](CONTEXT.md): canonical Bau project language.
- [Architecture](docs/architecture.md): boundaries between manifest, resolved
  state, operations, command surfaces, dependencies, automation, and publishing.
- [User guide](docs/user-guide.md): concepts, Project Manifest reference, command reference,
  and MCP details.
- [Workflow guide](docs/workflow-guide.md): task-oriented recipes for starting,
  converting, developing, caching, workspaces, CI, and publication.
- [ADRs](docs/adr/): short records for hard-to-reverse architecture decisions.

## Project Status

Bau is experimental but usable. The repository builds itself, runs its test
suite, generates documentation, converts Nimble projects, manages dependency
locks, supports workspaces, exposes MCP tools, and publishes Nimble-compatible
package metadata.
