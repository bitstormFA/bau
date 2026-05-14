# Bau Workflow Guide

This guide explains Bau from the perspective of day-to-day Nim development
workflows. The reference guide describes every command and configuration field;
this document answers "what do I do next?" when you are creating a project,
moving an existing Nimble package to Bau, changing code, updating dependencies,
generating documentation, using MCP tools, and preparing a release.

All examples assume `bau` is available on `PATH`. If you built Bau locally, use
the path to your binary, for example `build/dev/bau`, until you install it.

## Workflow Map

| Task | Typical commands |
|---|---|
| Create a new package | `bau new myapp`, `bau deps sync`, `bau test` |
| Convert a Nimble package | `bau convert --dry-run`, `bau convert`, `bau deps sync`, `bau tailor --write`, `bau test` |
| Work locally | `bau check`, `bau test`, `bau run -- args`, `bau build -p release` |
| Work with changed files | `bau affected list --since origin/main`, `bau affected test --since origin/main` |
| Add a dependency | `bau add pkg --version ">=1.0"`, `bau deps sync`, `bau deps verify`, `bau test` |
| Update dependencies | `bau deps update`, `bau deps verify`, `bau check --all-targets`, `bau test` |
| Generate API docs | `bau doc`, `bau doc --open`, `bau doc --out-dir site/api` |
| Connect an AI coding tool | `bau mcp`, then configure Claude Code or VS Code Copilot as a stdio MCP server |
| Prepare a release | `bau bump --patch`, `bau deps sync --locked`, `bau ci`, `bau doc`, `bau package --list --dry-run`, `bau publish --dry-run` |
| Publish to Nimble | Remove local patches/path deps, then `bau publish` |

## The Mental Model

Bau keeps a Nim project reproducible by separating intent, resolved state, and
outputs:

- `bau.toml` is the source of truth you edit. It declares package metadata,
  build targets, profiles, features, dependencies, docs, tasks, cache settings,
  and policy.
- `deps/` contains dependencies materialized by Atlas. Bau delegates fetching
  and package resolution to Atlas, then inspects what is on disk.
- `bau.lock` records the resolved dependency graph. It includes direct
  requirements, source identity, exact versions or Git revisions, dependency
  edges, checksums, workspace member metadata, and lock-time metadata.
- `build/` contains compiled outputs, fingerprints, task cache entries, package
  manifests, and other generated build artifacts.
- `bau.local.toml` is for local-only overrides. Do not use it for requirements
  other developers or CI must share.

There are two reproducibility layers:

- Dependency reproducibility comes from `bau.lock`. `bau deps sync` and
  `bau deps update` rewrite the lock after successful materialization. In CI,
  `bau deps sync --locked` fails if the lock is missing or stale, and
  `bau deps sync --frozen` also avoids network access and verifies local
  material against the lock.
- Build reproducibility comes from fingerprints and task cache keys. Target
  fingerprints include source contents, compiler flags, config files,
  Bau-related environment, compiler version, profile, platform, toolchain, and
  mtimes. Task cache keys include command text, inputs, outputs, selected
  features, environment inputs, platform, and Nim version.

The practical result is simple: commit `bau.toml` and `bau.lock`, keep generated
outputs out of the source tree unless you intentionally publish them, and use
`--locked` or `--frozen` in automation.

## Install Bau Once

From the Bau repository:

```sh
nimble install parsetoml
nim c --path:src -o:build/dev/bau src/bau.nim
```

Move `build/dev/bau` to a directory on `PATH`, or call it by path.

In a project, check the local setup:

```sh
bau doctor
bau env --json
```

`bau doctor` verifies configured toolchain requirements. `bau env --json`
prints the resolved profile, features, Nim path, and Atlas path that tools can
consume.

## Start a New Project

For a new binary:

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

`bau new` creates a minimal project with `bau.toml`, `src/`, `tests/`, and
development/release profiles. Review the generated `bau.toml` early, especially
the metadata that downstream users and package registries will see:

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

For team projects, add explicit toolchain expectations:

```toml
[toolchain]
nim = ">=2.2"
atlas = ">=0.8"
```

Then commit the initial reproducible state:

```sh
bau deps sync
bau deps verify
bau test
git add bau.toml bau.lock src tests
git commit -m "Start Bau project"
```

## Convert an Existing Nimble Project

Start from a clean Git working tree so the generated changes are easy to
review:

```sh
git status --short
bau convert --dry-run
```

If the dry run looks reasonable, write `bau.toml`:

```sh
bau convert
bau deps sync
bau tailor --check
bau check --all-targets
bau test
```

If `bau tailor --check` reports missing executable targets, let Bau append them:

```sh
bau tailor --write
bau check --all-targets
bau test
```

The converter is intentionally static. It converts deterministic Nimble
metadata such as package fields, `srcDir`, `bin`, `namedBin`, `backend`,
`requires`, feature-scoped `requires`, package include/exclude lists, literal
tasks, and literal build/install hooks. It does not execute NimScript. If your
`.nimble` file contains dynamic logic, Bau emits diagnostics and leaves the
missing behavior for you to model explicitly with profiles, features, tasks, or
build scripts.

Common Nimble automation patterns map cleanly once they are made explicit:

- A Nimble task that compiles a tool and forwards `commandLineParams()` can
  become a Bau task with `acceptArgs = true` and `{args}`, or a runnable target
  invoked with `bau run <target> -- ...`.
- A project-level test runner can be declared with `[test].runner`, and a
  debug/release/danger matrix can be declared with `[test].profiles`.
- Multi-step Nimble tasks are usually clearer as several `[[tasks]]` entries
  connected with `deps`.
- A project command that conflicts with a Bau built-in can be restored with an
  alias such as `lint = "task lint"` in `[aliases]`.

A good migration review looks like this:

```sh
git diff -- bau.toml bau.lock
bau metadata --json
bau graph --format dot
bau package --list --dry-run
bau publish --dry-run
```

Use `bau publish --dry-run` even if you are not publishing yet. It prints the
generated `.nimble` content, which is a useful compatibility check for packages
that still need to appear in the Nimble ecosystem.

## Daily Development On The CLI

After cloning a Bau project:

```sh
bau deps sync --locked
bau doctor
bau test
```

During a normal edit loop:

```sh
bau check
bau test
bau run -- --help
```

For larger suites with a canonical runner or several build modes:

```toml
[test]
runner = "tests/all.nim"
profiles = ["dev", "release", "danger"]
defaultProfile = "dev"
fullProfiles = ["dev", "release", "danger"]
recursive = true
exclude = ["thelper.nim"]
showOutput = "auto"
```

Use `bau test --show-output=always` when you want every compiler and runner
line streamed live. Use `bau test --fast` for the tight edit loop, `bau test
--dry-run` to inspect the planned profile/test invocations, and `bau test
--full` before handing work to CI. `bau ci` uses the full configured matrix when
`fullProfiles` or `profiles` is present.

For release-like local builds:

```sh
bau build --profile release
bau run --profile release -- --version
```

For feature-gated work:

```sh
bau build --features db
bau test --features db
bau build --no-default-features --features db
bau build --all-features
```

When you only want to run work affected by a branch:

```sh
bau affected list --since origin/main
bau affected test --since origin/main
bau affected check --since origin/main
```

When a rebuild happens and you expected a cache hit:

```sh
bau explain
bau explain --json
```

When your editor or LSP needs exact compiler command lines:

```sh
bau compile-commands --profile dev
bau compile-commands --profile release --features db --jobs 8
```

For a full local gate before opening a pull request:

```sh
bau fmt
bau lint
bau test
bau ci
```

`bau ci` runs formatting, linting, and tests. In larger repositories you may
prefer the explicit commands in CI so each step has separate logs.

## Daily Development Through MCP

Bau includes an MCP server. It exposes Bau operations as tools, so an AI tool
can build, test, inspect dependencies, generate docs, and read project metadata
without guessing shell commands.

Start the server manually for a smoke test:

```sh
bau mcp
```

The command speaks MCP over standard input/output, so it will wait for a client.
Stop it with `Ctrl+C` if you started it directly.

### Claude Code

Claude Code supports local stdio MCP servers. The current official Claude Code
MCP documentation describes adding a stdio server with `claude mcp add` and
checking server status with `/mcp`:
<https://code.claude.com/docs/en/mcp>

From the root of a Bau project:

```sh
claude mcp add --transport stdio --scope project bau -- bau mcp
claude mcp list
```

Project scope writes a `.mcp.json` file that can be committed for the team. A
minimal checked-in version looks like this:

```json
{
  "mcpServers": {
    "bau": {
      "type": "stdio",
      "command": "bau",
      "args": ["mcp"]
    }
  }
}
```

If `bau` is not on every developer's `PATH`, use an absolute command path or a
small wrapper script that your team documents. Claude Code prompts before using
project-scoped MCP servers from `.mcp.json`; run `/mcp` inside Claude Code to
approve and inspect the connection.

Useful Claude Code requests once connected:

```text
Use the bau tools to show project metadata and summarize the targets.
Run the Bau affected analysis against origin/main, then test only affected work.
Add jsony as a dependency, sync deps, and run the test suite.
Generate Bau docs and report any missing module documentation warnings.
```

### GitHub Copilot In VS Code

GitHub documents MCP support for Copilot Chat in VS Code, including manual
configuration in `.vscode/mcp.json`, Agent mode, and the tools picker:
<https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/extend-copilot-chat-with-mcp>

VS Code's MCP configuration reference documents the stdio shape used below:
<https://code.visualstudio.com/docs/copilot/reference/mcp-configuration>

Create `.vscode/mcp.json` in the project:

```json
{
  "servers": {
    "bau": {
      "type": "stdio",
      "command": "bau",
      "args": ["mcp"]
    }
  }
}
```

Then:

1. Open the repository in VS Code.
2. Open `.vscode/mcp.json` and use the inline Start action, or run
   `MCP: List Servers` from the command palette and start `bau`.
3. Open Copilot Chat.
4. Select Agent mode.
5. Use the tools icon to confirm Bau tools are available.

For Copilot Business or Enterprise users, your organization must allow MCP
servers in policy before Copilot can use them. VS Code also asks you to trust a
workspace MCP server when it starts.

Useful Copilot prompts:

```text
Use the Bau MCP server to run bau_check and fix the reported compile errors.
Use bau_query to explain why parsetoml is present, then summarize the dependency path.
Run bau_doc with skipExamples=false and fix documentation failures.
Use bau_compile_commands after changing feature flags.
```

### What The MCP Server Exposes

Common tools include:

- Build and validation: `bau_build`, `bau_run`, `bau_test`, `bau_check`,
  `bau_doc`, `bau_fmt`, `bau_clean`, `bau_install`.
- Dependencies: `bau_deps`, `bau_add`, `bau_remove`, `bau_deps_verify`.
- Introspection: `bau_metadata`, `bau_graph`, `bau_query`, `bau_affected`,
  `bau_explain`, `bau_cache_explain`, `bau_compile_commands`.
- Project setup: `bau_init`, `bau_convert`.

Read-only resources include `bau://config`, `bau://targets`, `bau://deps`,
`bau://tasks`, and `bau://status`.

## Dependency Workflows

Bau dependencies move through three states:

1. Declared in `[dependencies]` inside `bau.toml`.
2. Materialized on disk in `deps/` by Atlas.
3. Resolved and checksummed in `bau.lock` by Bau.

This is why dependency workflows usually include both a config edit and a sync.

### Add A Registry Dependency

```sh
bau add jsony --version ">=1.1.0"
bau deps sync
bau deps verify
bau test
git add bau.toml bau.lock
git commit -m "Add jsony dependency"
```

### Add A Git Or Path Dependency

```sh
bau add mylib --git https://github.com/example/mylib --tag v1.2.0
bau deps sync
bau test
```

For local development against a neighboring checkout:

```sh
bau add mylib --path ../mylib
bau deps sync
bau test
```

Path dependencies are convenient locally but cannot be reproduced by the Nimble
registry. Replace them with registry or Git dependencies before publication.

### Add An Optional Dependency

Optional dependencies are not fetched unless a feature enables them:

```sh
bau add sqlite --version ">=3.0" --optional
```

Then add a feature:

```toml
[features]
default = []
db = ["dep:sqlite"]
```

Work with the optional dependency enabled:

```sh
bau deps sync --features db
bau build --features db
bau test --features db
```

### Update All Dependencies

Use a branch so lockfile changes are easy to review:

```sh
git switch -c deps/update
bau deps update
bau tree
bau deps verify
bau check --all-targets
bau test
bau package --list --dry-run
git diff -- bau.lock
```

If the lock changed but tests pass, commit both the source config and lock:

```sh
git add bau.toml bau.lock
git commit -m "Update dependencies"
```

### Update One Materialized Git Dependency Precisely

When you need an exact revision:

```sh
bau deps update mylib --precise abc123def456
bau deps verify
bau test
```

`--precise` currently expects the dependency to already be materialized as a Git
checkout under `deps/<name>`.

### Patch A Dependency Temporarily

Use `[patch]` when you need to test a local fix without changing the public
dependency declaration:

```sh
bau deps patch parsetoml --path ../parsetoml
bau deps sync
bau test
bau query why parsetoml
```

Before publishing, remove patches and re-run validation:

```sh
bau deps sync
bau deps verify
bau publish --dry-run
```

A real `bau publish` rejects `[patch]` entries and local path dependencies.

### Work Offline Or In CI

For CI that is allowed to fetch dependencies but must not accept stale lock
state:

```sh
bau deps sync --locked
bau deps verify
bau ci
```

For a hermetic environment where dependencies are already present:

```sh
bau deps sync --frozen
bau deps verify
bau ci
```

`--frozen` is shorthand for `--locked --offline`.

### Vendor Dependencies

If your deployment or compliance workflow needs a checked-in dependency copy:

```sh
bau deps sync --locked
bau deps vendor
bau deps verify
```

`bau deps vendor` copies `deps/` to `vendor/` and writes
`vendor/.bau-vendor-checksums` so accidental changes can be detected.

## Custom Tasks, Build Scripts, And Caching

Use custom tasks for project automation that is not just "compile this Nim
target": generating assets, producing a site, running benchmarks, packaging
fixtures, or invoking external tools.

```toml
[[tasks]]
name = "site"
description = "Build the documentation site"
cmd = "nim r tools/build_site.nim"
inputs = ["docs/**/*.md", "tools/build_site.nim"]
outputs = ["site"]
cache = true
```

Run and inspect it:

```sh
bau task site
bau task --list
bau task site --help
bau cache explain site
bau cache explain site --json
```

Tasks that behave like small CLIs must opt in to arguments:

```toml
[[tasks]]
name = "fetch"
description = "Fetch a model shard"
cmd = "nim c -r tools/fetch.nim {argsWithSep}"
acceptArgs = true
```

Run it with:

```sh
bau task fetch -- cpu
```

The same arguments are also exposed as `BAU_TASK_ARGS`,
`BAU_TASK_ARG_0`, `BAU_TASK_ARG_1`, and so on for shell commands.

A cacheable task is skipped when its command, inputs, outputs, selected
features, arguments, relevant environment, platform, and Nim version match an
existing entry. If `[cache].remote` is configured, Bau can restore task outputs
from a shared filesystem cache or HTTP cache after a local miss.

Use build scripts when a pre-build step must influence the Nim compiler:

```toml
[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
outputs = ["src/generated/version.nim"]
```

Build scripts can emit directives such as:

```text
bau::rerun-if-changed=path
bau::rerun-if-env-changed=NAME
bau::nim-flag=--passC:-DUSE_X
bau::define=name=value
bau::link-lib=sqlite3
bau::generated-file=src/generated/version.nim
bau::warning=message
bau::error=message
```

The workflow is to declare inputs and outputs as specifically as possible, run
the task once, then use `bau cache explain <task>` when a cache hit or miss is
surprising.

## Documentation Workflow

Bau documentation generation wraps Nim's `nim doc` and applies the project's
profiles, features, dependencies, and doc configuration.

Start with a docs section:

```toml
[docs]
outDir = "docs/api"
entrypoints = ["src/myapp.nim"]
include = ["src/**/*.nim"]
exclude = ["src/**/private/**", "src/internal/**"]
runExamples = true
sourceUrl = "https://github.com/example/myapp/blob/main"
```

Write top-level Nim doc comments in public modules, then run:

```sh
bau doc
bau doc --open
```

While writing examples, keep `runExamples = true` so Nim validates runnable
examples. If you need a faster edit loop for layout-only changes:

```sh
bau doc --skip-examples
```

For a release or hosted site:

```sh
bau doc --out-dir site/api
bau package --list --dry-run
```

Bau writes a `.bau-docs-manifest` in the output directory so later doc
generations can clean previously generated files safely. It also warns when a
module has no top-level Nim doc comment, which is a useful pre-release quality
signal.

## Workspaces And Monorepos

In a workspace, the root `bau.toml` can define members, default members,
workspace dependencies, source providers, profiles, catalogs, and governance.
Member projects keep their own package-specific config.

A typical monorepo loop:

```sh
bau deps sync --locked
bau metadata --json
bau graph --format json
bau affected list --since origin/main
bau affected test --since origin/main
bau doc
```

Use catalogs when several members should share one version decision:

```toml
[workspace.catalog]
parsetoml = ">=0.6.0"
jsony = ">=1.1.0"
```

Then member projects can reference the catalog instead of repeating a version:

```toml
[dependencies]
jsony = "catalog:"
```

The root `bau.lock` covers the selected workspace member graph, which makes
cross-package updates reviewable in one place.

## CI Workflow

Use the same commands in CI that developers run locally. A conservative GitHub
Actions shape for a project that already has Bau installed in the CI image
looks like this:

```yaml
name: CI

on: [push, pull_request]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jiro4989/setup-nim-action@v1
        with:
          nim-version: stable
      - name: Verify dependencies
        run: bau deps sync --locked
      - name: Enforce dependency policy
        run: bau deps verify
      - name: Check, format, lint, and test
        run: bau ci
      - name: Build release binary
        run: bau build --profile release
      - name: Generate docs
        run: bau doc
      - name: Validate package
        run: bau package --list --dry-run
```

If Bau is not preinstalled, add an installation step appropriate for your
project. For example, build Bau from a pinned source checkout or from your
internal tool image before running the project commands.

For CI without network access:

```sh
bau deps sync --frozen
bau deps verify
bau ci
```

For large repositories, split the gate:

```sh
bau affected check --since origin/main
bau affected test --since origin/main
bau build --profile release --all-targets
bau doc --skip-examples
```

Use `bau metadata --json`, `bau graph --format json`, and
`bau affected list --json` when CI needs machine-readable summaries.

## Deployment And Publication

Deployment usually means "ship the release build somewhere"; publication means
"publish a Nim package through Nimble-compatible metadata." Bau supports both
flows.

### Deploy An Application Binary

Run a release preflight:

```sh
bau deps sync --locked
bau deps verify
bau ci
bau build --profile release
bau env --json
bau metadata --json
```

The release binary is written under `build/<profile>/` using the configured
`[build].output` name. Deploy that binary with your normal packaging system,
container image, system package, artifact upload, or `bau install --profile
release` for local installs. `bau install` defaults to `~/.bau/bin` and can be
redirected with `[install].dir` or `--install-dir`. Keep `bau.lock` with the
release commit so the dependency graph can be reconstructed later.

For repeatable generated assets, make them Bau tasks with declared inputs and
outputs, then run them before building:

```sh
bau task assets
bau build --profile release
```

### Publish A Library Or CLI Package

Before publishing, remove local-only overrides:

- No local path dependencies in `[dependencies]`.
- No `[patch]` entries.
- Registry-published libraries should use registry dependencies with version
  constraints. Git dependencies are better suited to applications or internal
  deployments unless you have a separate consumer story for them.
- No uncommitted generated metadata surprises.

Then run:

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

`bau package --list --dry-run` shows the files that would be included.
`bau publish --dry-run` validates package metadata and prints the generated
`.nimble` content without publishing.
Use `bau bump --major`, `bau bump --minor`, or `bau bump --patch` to update
`[package].version`; an existing `<package>.nimble` file is updated at the same
time.

When the dry run is clean:

```sh
git tag v0.3.1
bau publish
```

A real publish uses `nimble publish`. If the generated `.nimble` file does not
exist, Bau writes it from `bau.toml` before invoking Nimble.

## Troubleshooting Workflows

If dependencies fail in CI:

```sh
bau deps sync --locked
bau deps verify
bau tree
bau query why <dep>
```

If offline builds fail:

```sh
bau deps sync --offline
bau deps sync --frozen
```

The first command checks local material. The second also requires the lockfile
to be current.

If builds rerun unexpectedly:

```sh
bau explain
bau explain --json
bau clean
bau build --verbose
```

If a cached task reruns unexpectedly:

```sh
bau cache explain <task>
bau cache explain <task> --json
```

If docs fail:

```sh
bau doc --verbose
bau doc --skip-examples
bau doc --include-private
```

Use `--skip-examples` to separate Nimdoc layout or discovery problems from
runnable example failures. Use `--include-private` when a public entrypoint
depends on internal modules that you want to inspect.

If MCP tools do not appear:

```sh
which bau
bau mcp
claude mcp list
```

For VS Code, run `MCP: List Servers`, start the Bau server, and check the MCP
server output log. In both Claude Code and VS Code, project/workspace MCP
servers require user trust before tools are available.

## A Complete Example Branch

This is a realistic feature branch that changes code, adds a dependency,
updates documentation, and prepares a release candidate:

```sh
git switch -c feature/import-json

bau add jsony --version ">=1.1.0"
bau deps sync
bau deps verify

bau check
bau test
bau run -- --sample fixtures/example.json

bau doc
bau affected list --since origin/main
bau affected test --since origin/main

bau bump --minor
bau build --profile release
bau package --list --dry-run
bau publish --dry-run

git add bau.toml bau.lock src tests docs
git commit -m "Add JSON import workflow"
```

The important pattern is not the exact command list; it is the order:
declare intent, materialize dependencies, lock and verify, build and test,
generate docs, validate package contents, then commit the config and lockfile
together.
