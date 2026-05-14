# Bau

Bau, short for Baumeister, is an experimental build system for Nim projects.
It uses a `bau.toml` file to describe package metadata, build targets,
profiles, dependencies, scripts, and custom tasks.

## Documentation

- [Workflow guide](docs/workflow-guide.md): task-oriented examples for starting
  or converting projects, daily CLI and MCP work, dependency updates,
  documentation, CI, deployment, and publication.
- [User guide](docs/user-guide.md): reference-style documentation for commands,
  configuration fields, and Bau internals.

## Why Use It

- One project file for common Nim workflows: build, run, test, check, docs,
  formatting, linting, dependency sync, and CI checks.
- Named profiles keep development and release compiler settings explicit.
- Build fingerprints track source files, compiler flags, platform, toolchain,
  and profile so unchanged targets can be skipped.
- Multiple targets and workspaces allow a repository to build more than one
  executable or member project from the same command style.
- Atlas integration provides dependency syncing for Git, local path, and package
  dependencies declared in `bau.toml`.
- TOML lockfiles, dependency patching, trusted/blocked dependency policy, and
  workspace defaults help make multi-package repositories more reproducible.
- Feature flags, optional dependencies, cached build-script directives, and
  dependency catalogs make variant builds explicit.
- Task inputs/outputs, local or shared output caching, dry runs, metadata,
  affected-change analysis, and graph/query commands make project automation
  easier to inspect.
- Dependency verification, toolchain checks, and structured metadata help keep
  CI and editor integrations reproducible.
- Project scaffolding creates a basic binary or library layout with tests and
  default profiles.
- Nimble conversion turns existing `.nimble` package metadata, targets,
  dependencies, features, literal tasks, and hooks into a reviewable `bau.toml`.
- An MCP mode exposes real Bau build, test, docs, conversion, dependency,
  metadata, graph, affected, cache, and status operations to compatible tools.

## Example Configuration

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

[docs]
outDir = "docs"
entrypoints = ["src/myapp.nim"]
include = ["src/**/*.nim"]
exclude = ["src/**/private/**"]
runExamples = true

[install]
dir = "~/.bau/bin"

[dependencies]
parsetoml = ">=0.6.0"
sqlite = { version = ">=3.0", optional = true }

[features]
default = ["docs"]
docs = []
db = ["dep:sqlite"]

[catalog]
parsetoml = ">=0.6.0"

[patch]
parsetoml = { path = "../parsetoml" }

[toolchain]
nim = ">=2.2"
atlas = ">=0.8"

[cache]
dir = "build/.bau/cache"
read = true
write = true
remote = "file:///shared/bau-cache"

[governance]
blocked = ["badpkg"]
trusted = ["parsetoml"]
minimumReleaseAgeHours = 24

[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
outputs = ["src/generated/version.nim"]

```

## Common Commands

```sh
bau build
bau build --profile release
bau build --features db
bau run -- arg1 arg2
bau test
bau check
bau doc
bau doc --open
bau doc --out-dir site/api --skip-examples
bau install --profile release
bau install --update
bau uninstall
bau shell-init
bau convert --dry-run
bau convert --force
bau fmt
bau lint
bau ci
bau deps
bau deps lock
bau deps sync --locked
bau deps sync --frozen
bau deps update parsetoml --precise abc123
bau deps verify
bau deps patch parsetoml --path ../parsetoml
bau metadata --json
bau metadata --json --format-version 1
bau graph --format dot
bau graph --format json
bau query why parsetoml
bau affected list --since origin/main --json
bau affected test --since origin/main
bau cache list
bau cache explain docs --json
bau bump --patch
bau package --list --dry-run
bau publish --dry-run
bau tailor --check --json
bau compile-commands --profile release --features db --jobs 8
bau doctor
bau clean
```

Common global options:

```sh
bau build --jobs 8 --color never --quiet
bau deps sync --locked
bau deps sync --offline
bau deps sync --frozen
```

`--jobs` defaults to the detected CPU count and is forwarded to Nim as
`--parallelBuild:<n>`. `--color` accepts `auto`, `always`, or `never` and is
applied to Bau output and Nim color flags. `--quiet` suppresses nonessential Bau
progress logs while keeping warnings and errors. `--frozen` is shorthand for
`--locked --offline`.

Project creation:

```sh
bau init
bau init myapp --lib --version 0.1.0 --description "A Nim library"
bau new path/to/project
bau new path/to/library --lib
```

`bau init` prompts for any project metadata that is not provided on the
command line.

Nimble migration:

```sh
bau convert              # convert the only .nimble file in the current dir
bau convert path/to/pkg  # convert a package directory
bau convert pkg.nimble   # convert one file explicitly
bau convert --dry-run    # print generated TOML without writing
bau convert --json       # print diagnostics and summary as JSON
```

The converter is intentionally static: it does not execute NimScript. Dynamic
control flow is skipped with diagnostics so the generated `bau.toml` stays
deterministic and reviewable.

Dependency editing:

```sh
bau add parsetoml
bau add sqlite --optional
bau add mylib --git https://example.com/mylib.git --tag v1.0.0
bau add localpkg --path ../localpkg
bau remove parsetoml
```

Feature flags are declared in `[features]`. Enabled features become Nim defines
named after the feature, with non-identifier characters converted to `_`. Optional
dependencies are enabled by feature entries such as `dep:sqlite`.

Build scripts are declared with `[[buildScripts]]`. They run before compilation
and can print directives such as `bau::rerun-if-changed=path`,
`bau::nim-flag=--passC:-DUSE_X`, `bau::define=name=value`,
`bau::link-lib=sqlite3`, `bau::generated-file=src/generated/version.nim`,
`bau::warning=message`, and `bau::error=message`.

Build-script output is cached separately from target fingerprints. Bau reruns a
script when its command, profile, features, declared inputs, generated files, or
declared environment variables change. Scripts can declare those dependencies
with `bau::rerun-if-changed=path` and `bau::rerun-if-env-changed=NAME`.

Task outputs are cached when a task declares `inputs` and `outputs` or sets
`cache = true`. `bau cache explain <task>` shows the cache key and whether the
current inputs have a stored output entry. Cache keys include the task command,
shell, profile, features, working directory, task environment, platform, Nim
version, config inputs, declared inputs, declared outputs, and any environment
variables listed in `envInputs`.

Local cache entries are used first. Local writes are staged under a cache lock
and moved into place as a complete entry; restores validate the manifest and
stage outputs before replacing declared files. If `[cache].remote` is configured,
Bau tries the remote cache after a local miss and populates it after local
writes. Remote cache v1 supports local/shared paths, `file://` URLs, and
HTTP(S) endpoints that accept GET and PUT of one versioned JSON plus base64
payload at `/tasks/<task>/<key>.json`. Restores validate task/key identity,
output boundaries, relative paths, and file hashes before writing.
Authentication and remote execution are not part of this first cache protocol.

`bau cache explain <task> --json` reports the key inputs, local hit state,
remote hit/miss/error state, and restored outputs.

## Dependency Reproducibility

`bau deps lock` writes `bau.lock` as TOML, including URL/path, version, tag,
branch/revision, source identity, resolved package version, dependency edges,
checksums, workspace members, and lock-time metadata where available. The lock
format is versioned; current Bau writes `version = 2` resolved graph locks and
rejects older lockfiles with a regenerate message. Workspace roots use one root
`bau.lock` covering the selected member graph instead of one lock per member.

Non-optional registry or Git dependencies must be materialized locally before
Bau will accept a lock as reproducible. `bau deps sync --locked` fails before
invoking Atlas if the lockfile is missing or stale. `bau deps sync --offline`
checks that enabled dependency material is already present locally and that
checksums match when they are recorded. `bau deps sync --frozen` performs both
checks. `bau deps update <dep> --precise <rev>` checks out an exact revision for
a materialized Git dependency before rewriting the lock.

Source configuration is declared with `[source.<name>]` tables. Registry,
directory/vendor, local-registry mirror, Git, and `replaceWith` entries are
parsed into the lock source model; source replacement is for identical mirrors,
while `[patch]` remains the mechanism for changing dependency content.

`bau deps vendor` copies `deps/` to `vendor/` and writes
`vendor/.bau-vendor-checksums` so vendored material can be checked for accidental
changes.

`bau deps verify` enforces blocked dependencies, the trusted allowlist when
configured, lockfile freshness, recorded checksums, and
`minimumReleaseAgeHours`. Because Atlas does not expose registry release
timestamps, Bau enforces this policy against the lock entry's first-seen
`lockedAt` timestamp for materialized non-local dependencies; path dependencies
are ignored by this release-age gate.

## Build From Source

Install Nim and make sure `parsetoml` is available, then compile the CLI:

```sh
nimble install parsetoml
nim c --path:src -o:build/dev/bau src/bau.nim
```

The resulting binary is `build/dev/bau`.

## Configuration Model

Bau reads `bau.toml` from the project root. Optional local overrides can be
placed in `bau.local.toml`, and global defaults are read from the user's config
directory. Profiles may extend other profiles, and environment variables with
the `BAU_` prefix can add selected development settings.

Workspaces may define dependency catalogs under `[workspace.catalog]` or
`[workspace.catalogs.<name>]`. Member projects can reference these versions with
`catalog:` or `catalog:<name>` in dependency versions, keeping multi-package
version updates in one place.

Workspace roots can set `members`, `defaultMembers`, and `exclude`. Bau resolves
these entries centrally and reuses the same member set for workspace builds,
dependency lock/sync/verify, metadata, graph/query output, affected checks,
compile command generation, and tailor.

Custom tasks are declared with `[[tasks]]` entries and run with:

```sh
bau task <name>
```

`bau tailor --check --json` prints a deterministic report of missing target
declarations discovered from Nim sources. `bau affected` and `bau tailor` share
the same Nim scanner, including grouped imports, multiline imports, aliases,
`from ... import`, includes, common stdlib exclusions, and duplicate module-name
handling. `bau tailor --write` appends only missing targets and avoids duplicate
target names.

`bau compile-commands` writes a recursive, target-aware `compile_commands.json`
for `src/` and `tests/`, honoring profile, feature, and job settings.

`bau doc` builds first-class Nim API documentation from project source. It
discovers public modules under `[build].source`, adds configured entrypoints and
targets, skips conventional `private/` and `internal/` modules unless they are
explicitly included, forwards profile/features/dependency search paths, uses
Nimdoc `--project` and `--docRoot:@path`, and writes an indexed output tree.
The `[docs]` section can set `outDir`, `entrypoints`, `include`, `exclude`,
extra Nimdoc `flags`, `project`, `index`, `runExamples`, `includePrivate`, and
`sourceUrl`.

MCP mode exposes the same operation layer for metadata, graph, query, affected,
conversion, cache explain, dependency verification, and compile command
generation, so advertised tools no longer return synthetic success for
unsupported work.

`bau package --dry-run` performs package validation and lists included files.
`bau publish --dry-run` performs full local validation without network access
and prints the generated nimble file content. A real publish rejects local path
dependencies and `[patch]` overrides because those cannot be reproduced by the
registry.

## Status

Bau is currently version `0.3.2`. The existing implementation compiles, runs its
test suite, builds itself, and provides the main CLI surface for modern Nim
project automation.

Recent ergonomics include Nimble project conversion, `bau.lock` generation,
workspace dependency/profile defaults, task graph execution, package file
listing, metadata/query output, and `bau env --json` for tools that want the
resolved build environment.
