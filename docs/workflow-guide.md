# Bau Workflow Guide

This guide is organized around the work you do with Bau: start a project,
convert a Nimble package, build and test, manage dependencies, cache repeated
work, operate in a workspace, connect tools through MCP, and prepare releases.

For concepts and command reference, see [user-guide.md](user-guide.md). For
canonical project language, see [../CONTEXT.md](../CONTEXT.md). For the
architecture behind the terminology, see [architecture.md](architecture.md).

## Workflow Map

| Goal | Typical commands |
|---|---|
| Create a binary project | `bau new myapp`, `bau deps sync`, `bau check`, `bau test` |
| Create a library | `bau new mylib --lib`, `bau deps sync`, `bau test`, `bau doc --open` |
| Convert from Nimble | `bau convert --dry-run`, `bau convert`, `bau deps sync`, `bau tailor --check`, `bau test` |
| Daily local loop | `bau check`, `bau test`, `bau run -- args` |
| Release-like build | `bau deps sync --locked`, `bau deps verify`, `bau build --profile release` |
| Add dependency | `bau add pkg --version ">=1.0"`, `bau deps sync`, `bau deps verify`, `bau test` |
| Work with features | `bau build --features db`, `bau test --features db` |
| Inspect project state | `bau metadata --json`, `bau graph --format json`, `bau explain` |
| Run changed work | `bau affected list --since origin/main`, `bau affected test --since origin/main` |
| Cache a task | Declare `inputs` and `outputs`, then `bau task <name>`, `bau cache explain <name>` |
| Prepare publication | `bau package --list --dry-run`, `bau publish --dry-run` |
| Connect an AI tool | `bau mcp` |

## The Mental Model

Keep three things separate:

- **Project Manifest**: `bau.toml`, the intent you edit.
- **Resolved State**: `bau.lock`, especially dependency resolution.
- **Bau Outputs**: generated files such as binaries, docs, fingerprints, task
  cache entries, and package manifest outputs.

In practice:

```sh
git add bau.toml bau.lock src tests
```

Commit the manifest and lock together when dependency intent changes. Keep
generated outputs out of source control unless you intentionally publish them.
Treat `deps/` as generated project state: Bau builds and verifies against it,
but it is not the source intent you edit by hand.

## Start A New Project

For a binary:

```sh
bau new myapp
cd myapp
bau deps sync
bau check
bau test
bau run
```

For a library:

```sh
bau new mylib --lib
cd mylib
bau deps sync
bau test
bau doc --open
```

Review the generated manifest:

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
flags = ["--opt:speed"]
gc = "orc"
```

For a team project, add toolchain expectations early:

```toml
[toolchain]
nim = ">=2.2"
atlas = ">=0.8"
```

Then check and commit:

```sh
bau doctor
bau deps sync
bau deps verify
bau test
git add bau.toml bau.lock src tests
git commit -m "Start Bau project"
```

## Convert A Nimble Project

Start with a clean or understood worktree:

```sh
git status --short
bau convert --dry-run
```

The dry run shows the generated Project Manifest and conversion diagnostics.
Bau converts deterministic Nimble metadata, literal tasks, and literal hooks; it
does not execute dynamic NimScript.

Write the manifest:

```sh
bau convert
bau deps sync
bau tailor --check
bau check --all-targets
bau test
```

If Target Discovery finds missing executables:

```sh
bau tailor --write
bau check --all-targets
bau test
```

Plain `bau tailor` reports missing targets, `bau tailor --check` fails when any
are missing, and `bau tailor --write` edits the Project Manifest.

Review the conversion:

```sh
git diff -- bau.toml bau.lock
bau metadata --json
bau graph --format json
bau package --list --dry-run
bau publish --dry-run
```

Use `bau publish --dry-run` even when you are not publishing yet. It validates
Package metadata and shows generated Nimble-compatible metadata.

## Daily Development

After cloning:

```sh
bau deps sync --locked
bau doctor
bau test
```

During normal editing:

```sh
bau check
bau test
bau run -- --help
```

`bau check`, `bau lint`, and `bau test` are validation operations. `bau fmt` is
mutation because it rewrites source files. `bau build`, `bau run`, `bau doc`,
and `bau task` are execution operations unless a task is only wrapping
validation.

For a specific profile:

```sh
bau build --profile release
bau run --profile release -- --version
```

For all targets:

```sh
bau check --all-targets
bau build --all-targets
```

When a rebuild surprises you:

```sh
bau explain
bau explain --profile release
```

`bau explain` compares saved and fresh target fingerprints so you can see
whether sources, manifest inputs, environment, flags, profile, platform, or
toolchain changed.

## Tests

The simplest test command:

```sh
bau test
```

Filter by filename:

```sh
bau test config
```

Configure a Test Plan with a runner or matrix:

```toml
[test]
runner = "tests/tester.nim"
profiles = ["dev", "release", "danger"]
defaultProfile = "dev"
fullProfiles = ["dev", "release", "danger"]
recursive = true
exclude = ["thelper.nim"]
showOutput = "auto"
```

Useful test options:

```sh
bau test --no-matrix
bau test --test-profile release
bau test --full
bau test --fast
bau test --show-output always
bau test --dry-run
```

`--fast` is for the tight local loop. `--full` is the pre-merge or CI shape.
The Test Plan is not a Task unless you wrap testing in a user-declared task.

## Features And Optional Dependencies

Declare optional dependency requirements:

```toml
[dependencies]
sqlite = { version = ">=3.0", optional = true }

[features]
default = ["cli"]
cli = []
db = ["dep:sqlite"]
```

Use them:

```sh
bau build --features db
bau test --features db
bau build --no-default-features --features db
bau build --all-features
```

Feature names become Nim defines such as `-d:bauFeature_db` and `-d:db`.
Tasks and build scripts also receive `BAU_FEATURE_DB=1`.

## Dependency Workflows

Add a registry dependency:

```sh
bau add jsony --version ">=1.1.0"
bau deps sync
bau deps verify
bau test
git diff -- bau.toml bau.lock
```

Add a Git dependency:

```sh
bau add mylib --git https://github.com/example/mylib --tag v1.2.0
bau deps sync
bau deps verify
```

Add a local path dependency for development:

```sh
bau add localpkg --path ../localpkg
bau deps sync
```

Use a patch when you need to test a local fix without changing the public
dependency requirement:

```sh
bau deps patch parsetoml --path ../parsetoml
bau deps sync
bau test
```

Before publishing, remove patches and local path dependencies:

```sh
bau deps verify
bau publish --dry-run
```

Update dependencies:

```sh
git switch -c deps/update
bau deps update
bau deps verify
bau check --all-targets
bau test
git diff -- bau.lock
```

Pin a materialized Git dependency exactly:

```sh
bau deps update mylib --precise abc123def456
bau deps verify
bau test
```

Inspect why a dependency exists:

```sh
bau tree
bau query why jsony
bau query deps myapp
```

## Locked, Offline, And Frozen

For CI that may fetch dependencies but must reject stale locks:

```sh
bau deps sync --locked
bau deps verify
```

For hermetic environments where dependency material must already exist:

```sh
bau deps sync --frozen
bau deps verify
```

`--frozen` is shorthand for `--locked --offline`.

Dependency sync and lock operations mutate dependency material or resolved
state. In read-only CI stages, prefer `bau deps verify` after dependency
material has already been prepared, or use `bau deps sync --frozen` only when
the stage is allowed to validate existing material.

Vendoring copies dependency material and writes checksums:

```sh
bau deps sync --locked
bau deps vendor
bau deps verify
```

## Tasks And Caching

Declare a task:

```toml
[[tasks]]
name = "site"
description = "Build the documentation site"
cmd = "nim r tools/site.nim"
inputs = ["docs/**/*.md", "tools/site.nim"]
outputs = ["build/site"]
cache = true
```

Run it:

```sh
bau task site
bau task site --dry-run
bau task site -- --draft
```

Allow task arguments:

```toml
[[tasks]]
name = "bench"
cmd = "nim r tools/bench.nim"
acceptArgs = true
```

Arguments after `bau task <name> --` are passed only to the invoked root task,
not to dependency tasks. Prefer `BAU_TASK_ARG_0`, `BAU_TASK_ARG_1`, and
`BAU_TASK_ARGS` inside scripts. Use `{args}` and `{argsWithSep}` only when a
task is forwarding arguments to another command.

Explain the task cache:

```sh
bau cache explain site
bau cache explain site --json
bau cache list
bau cache clean
```

A Task Cache Entry restores declared outputs. Target compilation freshness uses
Target Fingerprints instead; use `bau explain` for target freshness and
`bau cache explain` for task output reuse.

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
not to dependency tasks. Prefer `BAU_TASK_ARG_0`, `BAU_TASK_ARG_1`, and
`BAU_TASK_ARGS` inside scripts. Use `{args}` and `{argsWithSep}` only when a
task is forwarding arguments to another command.

Local task cache entries live inside the project output boundary. Remote cache
entries live in the configured cache service or shared filesystem. Restoring a
remote entry is part of task output reuse; writing one is a secondary
external-service side effect.

## Build Scripts

Use project-scoped Build Scripts for generation that affects compilation:

```toml
[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
```

Scripts can print Build Directives:

```text
bau::generated-file=src/generated/version.nim
bau::rerun-if-changed=.git/HEAD
bau::rerun-if-env-changed=BUILD_VERSION
bau::define=buildVersion=1.2.3
bau::link-lib=sqlite3
bau::nim-flag=--passC:-DUSE_X
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

Build Scripts are cached separately from Target Fingerprints. They rerun when
their command, profile, selected features, inputs, generated files, or declared
environment inputs change.

That cached directive result is internal target-planning state, not a Task Cache
Entry. `bau cache` remains about user-invoked Tasks and their declared outputs.

Legacy Lifecycle Hooks run around actual build or install execution and do not
participate in Target Fingerprints. Use Build Scripts for generation, compiler
flags, generated files, or tracked build inputs.

## Documentation

Generate docs through Bau instead of raw `nim doc`:

```sh
bau doc
bau doc --open
bau doc --out-dir site/api
bau doc --skip-examples
bau doc --include-private
```

Configure docs:

```toml
[docs]
outDir = "docs"
entrypoints = ["src/myapp.nim"]
include = ["src/**/*.nim"]
exclude = ["src/**/private/**"]
runExamples = true
index = true
sourceUrl = "https://github.com/example/myapp/blob/main/{path}#L{line}"
```

For public libraries, run:

```sh
bau test
bau doc --open
bau package --list --dry-run
```

## Workspaces

A workspace coordinates member Bau Projects:

```toml
[workspace]
members = ["pkg/core", "pkg/utils", "apps/cli"]
defaultMembers = ["apps/cli"]
exclude = ["pkg/deprecated"]

[workspace.catalog]
jsony = ">=1.1.0"
parsetoml = ">=0.6.0"
```

Member projects keep their own manifests. The workspace root can provide shared
defaults for dependencies, sources, profiles, catalogs, and governance.

Typical workspace loop:

```sh
bau deps sync --locked
bau metadata --json
bau graph --format json
bau affected list --since origin/main
bau affected test --since origin/main
bau doc
```

Catalog references keep versions central:

```toml
[dependencies]
jsony = "catalog:"
parsetoml = "catalog:"
```

The root lock covers the selected member graph, so cross-member dependency
updates are reviewable in one place.

## Affected Work

List changed work:

```sh
bau affected list --since origin/main
bau affected list --since origin/main --json
```

Run only affected work:

```sh
bau affected check --since origin/main
bau affected test --since origin/main
bau affected build --since origin/main
```

Bau combines Git changes with Nim module scanning. Changes to the Project
Manifest, lockfiles, dependencies, or vendor material intentionally take the
conservative path and mark broad work as affected.

`affected list` only reports the selection. `affected check` and
`affected test` validate the selected work. `affected build` builds it.

## MCP

Start the MCP server:

```sh
bau mcp
```

Example configuration shape for an MCP-capable tool:

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

Useful prompts for a connected coding tool:

```text
Use Bau metadata to summarize the project targets and dependencies.
Run Bau affected analysis since origin/main and test the affected work.
Add jsony as a dependency, sync dependencies, and run the test suite.
Generate compile_commands.json for the release profile with the db feature.
```

MCP exposes the same Operations as the CLI where the capabilities overlap, so
tool automation should not become a separate build path.

## CI

A conservative CI sequence:

```sh
bau deps sync --locked
bau deps verify
bau doctor
bau ci
bau doc --skip-examples
bau package --list --dry-run
```

`bau ci` is validation-only: it runs non-mutating validation gates and does not
invoke `bau fmt`. Run `bau fmt` separately when you intentionally want to
rewrite source formatting.

For larger repositories:

```sh
bau affected check --since origin/main
bau affected test --since origin/main
bau build --profile release --all-targets
bau doc --skip-examples
```

For offline CI:

```sh
bau deps sync --frozen
bau deps verify
bau ci
```

Generate CI template skeletons when helpful:

```sh
bau ci-template github
bau ci-template gitlab
```

## Deployment And Publication

Deployment means shipping a built application artifact. Publication means
submitting a Package and Package Contents to a registry-compatible channel.

Deploy an application binary:

```sh
bau deps sync --locked
bau deps verify
bau ci
bau build --profile release
bau env --json
bau metadata --json
```

The binary is written under `build/<profile>/` using the configured output name.
Ship it with your normal packaging system, container image, artifact upload, or
`bau install --profile release` for local installs.

`bau install`, `bau update`, and `bau uninstall` mutate local installed
artifacts. They are not Publication.

Prepare a library or CLI package for publication:

```sh
bau bump --patch
bau deps sync --locked
bau deps verify
bau check --all-targets
bau test
bau doc
bau package --list --dry-run
bau publish --dry-run
```

`bau package --list --dry-run` is validation with introspective output: it
checks whether Package metadata and Package Contents are acceptable while
showing the selected files.

`bau publish --dry-run` validates a possible Publication. Real `bau publish`
mutates external registry state.

`bau bump` mutates Package version intent in the Project Manifest. It is not
Publication and does not submit anything to a registry.

Before a real `bau publish`:

- Remove local path dependencies.
- Remove `[patch]` entries.
- Prefer registry dependency requirements for registry-published packages.
- Check generated Nimble-compatible metadata in the dry run.

When the dry run is clean:

```sh
git tag v0.4.3
bau publish
```

## Troubleshooting

If dependency sync fails in CI:

```sh
bau deps sync --locked
bau deps verify
bau tree
bau query why <dep>
```

If a target rebuilds unexpectedly:

```sh
bau explain
bau explain --profile release
```

If a cached task reruns unexpectedly:

```sh
bau cache explain <task>
bau cache explain <task> --json
```

If editor diagnostics do not match Bau:

```sh
bau compile-commands --profile dev
bau compile-commands --profile release --features db
```

If project shape and docs feel out of sync:

```sh
bau metadata --json
bau graph --format json
bau tailor --check
```

The usual Bau loop is: declare intent in `bau.toml`, materialize dependencies,
lock and verify resolved state, run build/test/docs operations, inspect outputs,
then commit the manifest and lock together.
