# Bau User Guide

Bau (Baumeister, German for "master builder") is a build system for the
[Nim](https://nim-lang.org) programming language. It replaces `nimble`'s build
orchestration with a single declarative configuration file (`bau.toml`),
deterministic lockfiles, incremental compilation via content fingerprinting,
remote task caching, feature flags, workspace support, and an embedded MCP
server for AI tool integration.

This guide assumes you are a professional software engineer already familiar
with Nim's compiler flags, package ecosystem, and the general shape of a Nim
project.

For task-oriented examples, see the [Bau Workflow Guide](workflow-guide.md).

---

## Table of Contents

1. [Concepts](#concepts)
2. [Installation](#installation)
3. [Getting Started](#getting-started)
4. [Migrating from nimble](#migrating-from-nimble)
5. [The bau.toml File](#the-bautoml-file)
6. [Build and Run](#build-and-run)
7. [Dependency Management](#dependency-management)
8. [Feature Flags](#feature-flags)
9. [Profiles](#profiles)
10. [Task Caching](#task-caching)
11. [Build Scripts](#build-scripts)
12. [Workspaces](#workspaces)
13. [Affected Analysis](#affected-analysis)
14. [Lockfile and Reproducibility](#lockfile-and-reproducibility)
15. [Dependency Governance](#dependency-governance)
16. [Documentation Generation](#documentation-generation)
17. [Command Reference](#command-reference)
18. [MCP Server](#mcp-server)
19. [Configuration Reference](#configuration-reference)

---

## Concepts

### How Bau differs from nimble

`nimble` is primarily a package manager that also builds Nim code. It derives
build settings from a `.nimble` file whose format mixes NimScript declarations
with package metadata. Bau separates concerns:

| Concern | nimble | Bau |
|---|---|---|
| Package metadata | `.nimble` NimScript | `bau.toml` (TOML) |
| Build targets | Implicit from `bin`/`srcDir` | Explicit `[build]` and `[[targets]]` |
| Dependencies | `requires` statements | `[dependencies]` table |
| Dependency resolution | Ad-hoc, no lockfile | Atlas + `bau.lock` v2 |
| Profiles | NimScript conditionals | Named `[profile.<name>]` with inheritance |
| Task execution | NimScript `task` blocks | `[[tasks]]` with cache and dependency graph |
| Feature flags | Manual `-d:` flags | Declared `[features]` with resolution |
| Reproducibility | None | Content-hashed fingerprints + lock checksums |

Bau delegates package fetching to [Atlas](https://github.com/nim-lang/atlas),
Nim's official package manager. It focuses on what Atlas does not do: build
orchestration, task scheduling, caching, policy enforcement, and workspace
management.

### Architecture at a glance

```
bau.toml          bau.lock         build scripts
    │                │                  │
    ▼                ▼                  ▼
┌─────────────────────────────────────────┐
│              Operation Layer (ops.nim)  │
├─────────────────────────────────────────┤
│  Build  │ Deps │ Cache │ Affected │ Doc │
├─────────────────────────────────────────┤
│              Config (config.nim)        │
└─────────────────────────────────────────┘
         │                    │
         ▼                    ▼
    CLI (stdio)         MCP (JSON-RPC)
```

Every command — whether invoked via CLI or the MCP server — goes through the
same operation layer. This means an AI agent using the MCP server runs the
exact same code paths as a human at the terminal.

### Fingerprints and incremental builds

Bau computes a **9-component fingerprint** for each build target:

| Component | What it captures |
|---|---|
| `sourceHash` | SHA-256 of every `.nim` file's full content |
| `flagsHash` | All compiler flags concatenated |
| `configHash` | Contents of `bau.toml`, `bau.local.toml`, global config |
| `envHash` | `BAU_*`, `PATH`, `NIM`, `ATLAS` environment variables |
| `compilerHash` | Nim version + OS/arch triple |
| `mtimeHash` | Modification timestamps of all source files |
| `profile` | The profile name |
| `platform` / `toolchain` | OS-arch triple and `"nim-<version>"` strings |

A rebuild is triggered only when at least one component differs from the stored
fingerprint. This is more precise than Make-style mtime checks: two checkouts
of the same commit on different machines produce identical fingerprints
(assuming the same Nim version), making Bau's cache safe to share across CI
runners.

### Task caching vs. target fingerprinting

Bau has **two separate caching systems** for different use cases:

1. **Target fingerprinting** (build.nim + fingerprint.nim): Optimized for Nim
   compilation. Hashes source content, flags, config, environment, and
   toolchain. A match means "the compiler would produce the same binary."

2. **Task caching** (taskcache.nim + taskgraph.nim): Generic content-addressed
   cache for arbitrary shell commands. Hashes input file contents, command
   strings, environment variables, platform, and Nim version. Supports local
   disk and HTTP remote backends.

They share cache directory and remote settings from `[cache]` but store entries
in separate subdirectories.

---

## Installation

**Prerequisites:** Nim >= 2.2 and `parsetoml`.

```sh
nimble install parsetoml
nim c --path:src -o:build/dev/bau src/bau.nim
```

Move `build/dev/bau` to a directory on your `$PATH`. Once Bau is available,
`bau shell-init` can add `~/.bau/bin` to your shell startup file for binaries
installed by `bau install`.

A bootstrap script is also available if you don't have nimble:

```sh
./bootstrap.sh
```

---

## Getting Started

### Creating a project

```sh
# Initialize in the current directory (interactive prompts)
bau init

# Create a new binary project in a subdirectory
bau new myapp

# Create a new library
bau new mylib --lib

# Non-interactive initialization with all metadata
bau init myapp --bin --version 0.1.0 --description "A Nim app" --license MIT
```

`bau init` scaffolds:
- `bau.toml` with package metadata, build config, and dev/release profiles
- `src/<name>.nim` (binary) or `src/<name>.nim` with `src/<name>/` package (library)
- `tests/t<name>.nim`
- Default dev and release profiles

### Building and running

```sh
bau build               # debug build (profile: dev)
bau build -p release    # optimized build
bau run                 # build and run
bau run -- --flag val   # pass arguments to the binary
bau test                # build and run tests
bau test config         # run only tests matching "config"
```

### The basic bau.toml

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

---

## Migrating from nimble

Use `bau convert` at the root of an existing Nimble package:

```sh
bau convert              # read the only .nimble file in the current directory
bau convert path/to/pkg  # convert a package directory
bau convert pkg.nimble   # convert a specific file
bau convert --dry-run    # print generated TOML without writing bau.toml
bau convert --json       # machine-readable conversion report
bau convert --force      # overwrite an existing bau.toml
```

The converter does not execute NimScript. It statically converts the parts of a
`.nimble` file that are deterministic package metadata: package name, version,
author/authors, description, license, `srcDir`, `bin`, `namedBin`, `backend`,
`requires`, feature-scoped `requires`, package include/exclude lists, literal
`task` commands, and literal `before build`, `after build`, and `after install`
hooks.

Nimble files can contain arbitrary NimScript control flow. Bau skips dynamic
blocks rather than guessing, emits diagnostics, and leaves reviewable TOML. A
typical migration loop is:

```sh
bau convert --dry-run
bau convert
bau deps sync
bau check --all-targets
bau tailor --write
bau test
```

After conversion, review any diagnostics, then use `bau tailor --write` to add
extra executable targets discovered from source files that were not declared in
the original `.nimble` metadata.

---

## The bau.toml File

Bau reads configuration from multiple sources, merged in order of precedence
(lowest to highest):

1. Global defaults from `~/.config/bau/config.toml` (shared across all projects)
2. Workspace-level defaults (if the project is a workspace member)
3. Project-level `bau.toml`
4. Local overrides from `bau.local.toml` (not committed to version control)
5. Environment variables with the `BAU_` prefix

This layering means you can define your personal compiler flags in
`~/.config/bau/config.toml` without polluting the project's committed
configuration, or override dependencies during local development via
`bau.local.toml`.

### Sections

A `bau.toml` can contain these sections:

| Section | Purpose |
|---|---|
| `[package]` | Name, version, description, license, edition |
| `[build]` | Default build target configuration |
| `[[targets]]` | Additional named build targets |
| `[profile.<name>]` | Named compiler profiles with inheritance |
| `[dependencies]` | Direct dependencies |
| `[features]` | Feature flag declarations |
| `[docs]` | Documentation generation settings |
| `[cache]` | Local and remote cache configuration |
| `[install]` | Binary installation destination |
| `[governance]` | Dependency allow/block lists and age policy |
| `[toolchain]` | Required tool versions |
| `[[tasks]]` | Custom task definitions |
| `[[buildScripts]]` | Pre-build scripts that emit directives |
| `[patch]` | Dependency overrides (local paths, pins) |
| `[source.<name>]` | Dependency source configuration |
| `[catalog]` / `[workspace.catalog]` | Centralized version catalogs |
| `[workspace]` | Multi-project workspace definition |

---

## Build and Run

### The build model

Bau builds **targets**. A target is either the default target defined in
`[build]` or a named target in `[[targets]]`. Each target resolves to a single
call to the Nim compiler.

During compilation, Bau:

1. Resolves the target plan (source files, output path, profile, compiler flags)
2. Runs build scripts (if any) and collects their emitted directives
3. Computes the fingerprint and compares it to the stored fingerprint
4. If the fingerprint matches and the binary exists, the build is skipped
5. Otherwise, invokes `nim <backend> <flags> --out:<binary> <main>`
6. Saves the new fingerprint

Build scripts run **before** the fingerprint check, so they always execute.
However, build scripts have their own caching layer — a script is skipped if
its cache key (command + inputs + environment) matches and all declared
generated files still exist with correct hashes.

### Targets

The default target comes from `[build]`:

```toml
[build]
kind = "bin"           # "bin" or "lib"
source = "src"         # source directory
main = "src/myapp.nim" # entry point
output = "myapp"       # output binary name
```

Additional targets are declared with `[[targets]]`:

```toml
[[targets]]
name = "cli"
kind = "bin"
main = "src/cli.nim"
profile = "release"
requiredFeatures = ["cli"]

[[targets]]
name = "bench"
kind = "bin"
main = "benchmarks/bench.nim"
profile = "release"
requiredFeatures = ["bench"]
```

Targets can override the profile and require specific feature flags. Targets
with unmet required features are silently skipped during `bau build --all-targets`.

### Build commands

```sh
bau build                # build default target (dev profile)
bau build cli            # build the "cli" target
bau build --profile release
bau build --features db
bau build --all-targets  # build every configured target
bau build --jobs 8       # parallel compilation (passed as --parallelBuild:8 to Nim)
bau build --verbose      # show the full Nim command line
bau build --timings      # show build timing information
bau build --watch        # watch files and rebuild on changes (uses inotify on Linux)
```

### Running

```sh
bau run                        # build and run default target
bau run cli                    # build and run the "cli" target
bau run -- --input file.txt    # arguments after -- go to the binary
bau run --profile release
```

### Installing

```sh
bau install                         # install the default binary
bau install cli                     # install the "cli" target
bau install --profile release
bau install --all-targets           # install every binary target
bau install --update                # update an already installed binary
bau update cli                      # same update action as bau install --update cli
bau uninstall cli                   # remove an installed binary
bau install --install-dir ~/.local/bin
bau shell-init                      # add ~/.bau/bin to your shell startup file
bau shell-init fish                 # configure a specific shell
```

By default, Bau installs binaries to `~/.bau/bin`. Set `[install].dir` or pass
`--install-dir` to use a different destination. Relative install directories
are resolved from the project root.

### Testing

```sh
bau test                  # build and run all tests
bau test "config"         # filter test files by name
bau test --changed        # only tests affected by current changes
bau test --profile test   # use the test profile
```

Bau discovers tests by convention: if `tests/tester.nim` exists, it runs that
file as the test runner. Otherwise it enumerates `tests/t*.nim` and runs each
file separately. If a `test` profile is defined in `bau.toml`, it is used
automatically.

### Checking

```sh
bau check                  # type-check default target (no binary produced)
bau check --all-targets    # type-check all configured targets
```

### Formatting and linting

```sh
bau fmt                    # format all .nim files in src/ via nimpretty
bau lint                   # check style with --styleCheck:error
bau ci                     # fmt + lint + test, fails fast
```

### Cleaning

```sh
bau clean                  # remove build/ directory
```

---

## Dependency Management

### How dependencies are resolved

Bau uses a three-layer dependency model:

1. **Declared** — What you write in `bau.toml`'s `[dependencies]` section.
   These are your intent: "I need parsetoml >= 0.6.0."

2. **Materialized** — What Atlas fetches onto disk in `deps/<name>/`.
   These are the concrete files on your filesystem.

3. **Resolved** — What `bau.lock` records: exact versions, git revisions,
   content checksums, and the full transitive dependency graph. The lock is the
   reproducible snapshot.

Bau never does its own package resolution. It delegates to Atlas for fetching,
and wraps Atlas's output in a lockfile with content-addressed integrity
verification.

### Declaring dependencies

Simple registry dependencies:

```toml
[dependencies]
parsetoml = ">=0.6.0"
jsony = ">=1.0"
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

Optional dependencies (not fetched unless a feature enables them):

```toml
[dependencies]
sqlite = { version = ">=3.0", optional = true }
analytics = { git = "https://...", optional = true }
```

### Source providers

Sources configure *where* a dependency is fetched from, independently of the
dependency declaration. This is useful for private registries, mirrors, or
vendored replacements:

```toml
[source."parsetoml"]
registry = "https://my-registry.example.com/nimble"

[source."internal-lib"]
git = "https://git.internal.company.com/internal-lib"

[source."vendored-lib"]
directory = "vendor/vendored-lib"

[source."mirror"]
replaceWith = "primary"   # indirection: "mirror" resolves to "primary"
```

Source replacement via `replaceWith` supports chaining with cycle detection. A
source that resolves to another source will follow the chain until a concrete
source (registry, git, path, vendor) is found.

The `[patch]` section is separate from `[source]` and serves a different
purpose: it changes the **content** of a dependency (e.g., overriding a
registry package with a local development path) rather than changing where a
source is fetched from:

```toml
[patch]
parsetoml = { path = "../parsetoml" }   # use local checkout instead of registry
```

### Syncing dependencies

```sh
bau deps                        # fetch and materialize all enabled dependencies
bau deps sync                   # explicit form of the above
bau deps sync --locked          # fail if bau.lock is missing or stale
bau deps sync --offline         # no network; verify local material matches lock
bau deps sync --frozen          # --locked + --offline
```

`bau deps` iterates over every enabled dependency and invokes Atlas:
- Git deps: `atlas use <url>#<rev|tag|branch>`
- Path deps: `atlas link <path>`
- Registry deps: `atlas use <name>` (Atlas resolves version constraints)

Optional dependencies are skipped unless a feature flag with `dep:<name>` is
active. This means optional deps are not fetched by default — you must enable
the corresponding feature.

### Adding and removing dependencies

```sh
bau add parsetoml                                   # registry dep, no version constraint
bau add parsetoml --version ">=0.6.0"               # with version
bau add mylib --git https://github.com/u/mylib --tag v1.0
bau add mylib --git https://github.com/u/mylib --branch main
bau add mylib --git https://github.com/u/mylib --rev abc123
bau add localpkg --path ../localpkg                  # local path
bau add sqlite --optional                            # optional dependency
bau add mypkg --registry my-registry                 # specific registry

bau remove parsetoml                                 # remove from bau.toml
```

These commands edit `bau.toml` directly — they parse the existing file, add or
remove lines in the `[dependencies]` section, validate the resulting TOML, and
write back. They do not regenerate or reformat the rest of the file.

### Updating dependencies

```sh
bau deps update parsetoml --precise abc123def   # pin to exact git revision
```

After updating, `bau deps lock` to rewrite the lockfile with the new revision.

### Dependency tree and inspection

```sh
bau tree                    # display the full dependency tree
bau outdated                # show packages with newer versions available
bau query deps myapp        # list all dependencies for a target
bau query why parsetoml     # explain why parsetoml is in the dependency graph
```

### Vendoring

```sh
bau deps vendor    # copy deps/ to vendor/ and write vendor/.bau-vendor-checksums
```

Vendoring creates a self-contained copy of all dependencies that can be
committed to version control. The checksum file enables `bau deps verify` to
detect accidental modifications to vendored code.

---

## Feature Flags

Feature flags enable conditional compilation and optional dependency activation.
They are declared in `[features]`:

```toml
[features]
default = ["docs", "cli"]     # features enabled by default
docs = []                     # standalone feature
db = ["dep:sqlite"]           # enables the optional sqlite dependency
cli = ["db"]                  # cli implies db
analytics = ["dep:analytics", "db"]  # analytics implies db and enables analytics dep
```

### Resolution

When you run `bau build --features analytics`, Bau resolves the feature
closure:

1. Seed: `default` features (unless `--no-default-features`)
2. Plus: explicitly requested features (`analytics`)
3. Resolve transitively: `analytics` → `db` and `dep:analytics`, `db` →
   `dep:sqlite`, `cli` (from default) → `db` (already visited)
4. Result: features `docs`, `cli`, `db`, `analytics` are enabled; deps `sqlite`
   and `analytics` are enabled.

### Compiler integration

Each enabled feature emits **two** Nim defines:

```
-d:bauFeature_docs        # namespaced, for Bau's own use
-d:docs                   # bare, for your code to check with when defined(docs)
```

Feature names are normalized: non-identifier characters become `_`. So a
feature named `my-feature` becomes `-d:bauFeature_my_feature` and
`-d:my_feature`.

Additionally, each enabled feature sets an environment variable for build
scripts: `BAU_FEATURE_<UPPERCASED_NAME>=1`.

### Usage

```sh
bau build --features db,analytics         # enable specific features
bau build --all-features                  # enable everything except "default"
bau build --no-default-features           # disable the default set
bau build --no-default-features --features db   # only "db" and its dependencies
```

---

## Profiles

Profiles group compiler settings. They support inheritance via `extends`:

```toml
[profile.dev]
flags = ["--debugInfo:on", "--linedir:on"]
gc = "orc"
defines = { debug = "" }

[profile.release]
flags = ["--opt:speed", "--passC:-O3", "--passL:-flto"]
gc = "orc"
defines = { release = "" }

[profile.test]
extends = "dev"
flags = ["--define:testing"]

[profile.danger]
extends = "release"
flags = ["-d:danger"]
```

Inheritance is resolved depth-first: `test` inherits all of `dev`'s settings,
then adds its own.

### Built-in profiles

`dev`, `release`, and `test` are conventional. Bau does not enforce their
presence — if you define only `debug` and `optimized`, those work fine.
`bau test` automatically uses the `test` profile if one is defined.

### Usage

```sh
bau build --profile release
bau build -p dev
bau test -p test
```

---

## Task Caching

### How it works

Bau caches the outputs of custom tasks and build scripts. A task is cacheable
when it declares both `inputs` and `outputs`, or explicitly sets `cache = true`.

The cache key is a SHA-256 hash of:

- Task command and name
- Profile, platform, Nim version
- Working directory
- Shell type
- Enabled features
- Content hashes of all input files
- Current values of declared environment variables
- Cache read/write settings

When a task runs and the key matches a stored entry, Bau restores the outputs
from cache and skips execution entirely. This means a task that generates
documentation or compiles assets only re-runs when its inputs actually change.

### Configuration

```toml
[cache]
dir = "build/.bau/cache"              # local cache directory
read = true                           # read from cache (default: true)
write = true                          # write to cache (default: true)
remote = "file:///shared/bau-cache"   # shared filesystem cache
# remote = "https://cache.internal/bau"  # HTTP remote cache
```

### Local cache

Entries are stored at `<cacheDir>/tasks/<taskName>/<sha256key>/`:
- `manifest.json` — key, task name, output paths
- `files/<relativePath>` — copies of each output file

Writes use a staging directory and atomic rename, so a crashed process never
leaves a partial cache entry. Restores validate the manifest key and task name
before copying files back.

### Remote cache

The remote protocol is HTTP-based:

- **Write**: `PUT /tasks/<taskName>/<key>.json` with a JSON body containing
  `version`, `task`, `key`, `outputs`, and `files` (base64-encoded content with
  SHA-256 hashes).
- **Read**: `GET /tasks/<taskName>/<key>.json`
- **Probe**: `HEAD /tasks/<taskName>/<key>.json` (for `cache explain`)

`file://` URLs are handled identically but read/write to the local filesystem
at the specified path, making them suitable for NFS-mounted shared caches in CI
environments.

File-level security is enforced on restore: outputs are validated to stay
within declared output directories, and symlinks are never overwritten
(mitigating symlink-based cache poisoning attacks).

### Cache commands

```sh
bau cache list                          # list all cache entries
bau cache explain docs                  # show cache key, local/remote hit status
bau cache explain docs --json           # machine-readable cache diagnosis
bau cache clean                         # remove all cache entries
```

---

## Build Scripts

Build scripts run **before** compilation and can influence the build by
emitting directives on stdout. They are the equivalent of Cargo's `build.rs` or
Meson's `run_command()`.

### Declaration

```toml
[[buildScripts]]
name = "version"
cmd = "nim r scripts/version.nims"
inputs = ["scripts/version.nims", ".git/HEAD"]
outputs = ["src/generated/version.nim"]

[[buildScripts]]
name = "assets"
cmd = "python tools/embed_assets.py"
inputs = ["assets/**", "tools/embed_assets.py"]
outputs = ["src/generated/assets.nim"]
envInputs = ["BUILD_ID"]
```

### Directives

Build scripts communicate with Bau by printing lines with the `bau::` prefix:

| Directive | Effect |
|---|---|
| `bau::rerun-if-changed=<path>` | Add a file whose change invalidates cache |
| `bau::rerun-if-env-changed=<VAR>` | Add an env var whose change invalidates cache |
| `bau::nim-flag=--passC:-DUSE_X` | Append a Nim compiler flag |
| `bau::define=name=value` | Add a `-d:name=value` define |
| `bau::link-lib=sqlite3` | Link a system library (`--passL:-lsqlite3`) |
| `bau::generated-file=<path>` | Declare a file the script generates |
| `bau::warning=<message>` | Emit a build warning |
| `bau::error=<message>` | Emit a build error (halts the build) |

Example NimScript (`scripts/version.nims`):

```nim
import std/[os, strutils]

let hash = gorgeEx("git rev-parse --short HEAD")[0].strip()
let version = readFile("bau.toml")
  .splitLines()
  .filterIt(it.startsWith("version ="))
  .mapIt(it.split("=")[1].strip().replace("\"", ""))[0]

echo "bau::generated-file=src/generated/version.nim"
echo "bau::rerun-if-changed=.git/HEAD"

writeFile("src/generated/version.nim", """
const AppVersion* = "$1"
const GitHash* = "$2"
""".format(version, hash))
```

### Caching

Build scripts have their own cache, separate from the target fingerprint. The
cache key includes the script command, all declared inputs (content-hashed),
and all declared environment variables (current values). When the key matches
AND all previously declared generated files still exist with matching hashes,
the script is skipped.

This means `build.rs`-style code generation is only re-invoked when its inputs
change, not on every build.

---

## Workspaces

Workspaces support monorepos with multiple interdependent Nim packages.

### Configuration

```toml
[workspace]
members = ["pkg/core", "pkg/utils", "pkg/client", "apps/cli", "apps/server"]
defaultMembers = ["apps/cli"]      # only these are built by default
exclude = ["pkg/deprecated"]

[workspace.catalog]
parsetoml = ">=0.6.0"              # shared version across all members
jsony = ">=1.0"
```

Each member directory contains its own `bau.toml`. Workspace-level defaults
(dependencies, sources, profiles, governance, catalogs) are merged into each
member's config. A member can override workspace defaults by declaring its own
entry for the same key.

### Workspace behavior

- **Lockfile**: One root `bau.lock` covers the entire workspace. It records
  which workspace member declared each dependency.
- **Default vs. all members**: `bau build` builds only `defaultMembers`.
  `bau affected list` scans all members. Use `bau build --workspace-all` to
  build everything.
- **Affected analysis**: Git changes at the workspace root are scoped to each
  member. A change in `pkg/core/` only affects members that import `pkg/core`.

### Catalog

Catalogs centralize version constraints. Instead of repeating `parsetoml =
">=0.6.0"` in every member, declare it once in the workspace catalog and
reference it from members:

```toml
# workspace root bau.toml
[workspace.catalog]
parsetoml = ">=0.6.0"

# member bau.toml
[dependencies]
parsetoml = "catalog:"              # uses version from workspace default catalog
jsony = "catalog:stable"            # uses version from [workspace.catalogs.stable]
```

---

## Affected Analysis

`bau affected` uses Git to determine what changed and what needs to be rebuilt
or retested.

### How it works

1. **Change detection**: Runs `git diff --name-only <ref>` to get changed files.
2. **Module scanning**: Scans all project `.nim` files to build an import graph.
   Uses both a static parser (fast, catches local `import`/`include`
   statements) and `nim genDepend` (slow but complete, catches dependencies
   resolved through `--path:` search paths).
3. **Transitive propagation**: Starting from changed `.nim` files, performs BFS
   through the reverse import graph to find all modules that transitively
   import or include a changed module.
4. **Classification**: Maps affected modules to targets (whose `main` file is
   affected), tests (whose test file is affected), and tasks (whose `inputs`
   glob patterns match changed files).

### Conservative triggers

When certain files change, Bau takes the conservative path and marks
**everything** as affected:

- `bau.toml`, `bau.local.toml`, `nim.cfg`, `config.nims`, `*.nimble`: all
  targets and tests are affected.
- `bau.lock`, `deps/**`, `vendor/**`: all targets are affected (a dependency
  change could affect any module).

### Usage

```sh
bau affected list                        # what changed since HEAD?
bau affected list --since origin/main    # what changed vs. main branch?
bau affected list --since HEAD~3         # what changed in the last 3 commits?
bau affected list --since origin/main --json

bau affected build                       # build only affected targets
bau affected test                        # test only affected tests
bau affected check                       # check only affected targets
```

### Tailor: discovering missing targets

`bau tailor` scans your Nim source files and finds modules with `isMainModule`
that aren't declared as targets:

```sh
bau tailor            # print discovered targets
bau tailor --check    # exit non-zero if targets are missing (for CI)
bau tailor --check --json
bau tailor --write    # append missing targets to bau.toml
```

---

## Lockfile and Reproducibility

### The bau.lock format

`bau.lock` is a TOML file (version 2) that records the fully resolved
dependency graph:

```toml
# bau.lock - @generated by bau, do not edit
version = 2
resolver = "atlas-bridge"
requirementsHash = "sha256:abc123..."
workspaceMembers = ["."]

[[rootDependency]]
name = "parsetoml"
requirement = ">=0.6.0"
source = "registry+nimble://default"
optional = false
enabledBy = []
workspaceMember = "."

[[package]]
name = "parsetoml"
version = "0.6.1"
source = "registry+nimble://parsetoml"
revision = "abc123def456..."
checksum = "sha256:xyz789..."
path = "deps/parsetoml"
direct = true
materialized = true
lockedAt = 1700000000
dependencies = ["jsony|>=1.0|jsony 1.2.0|false"]
```

Key properties:

- **`requirementsHash`**: A hash of all workspace members, dependency
  declarations, source entries, and feature entries. If this hash doesn't match
  the current config, the lock is stale.
- **`checksum`**: Content hash of the package's on-disk files. Computed by
  walking all non-`.git`, non-build files, sorting them, and hashing
  `relpath:sha256\n` entries.
- **`lockedAt`**: Unix timestamp of when this exact revision+checksum was first
  seen. Preserved across lockfile rewrites when the package hasn't changed.
- **`materialized`**: Whether the package's source code is present on disk.
  Non-materialized packages cause `--locked` and `--frozen` to fail.

### Lockfile operations

```sh
bau deps lock                              # generate or update bau.lock
bau deps lock --features db,analytics      # lock with specific features enabled
bau deps verify                            # check lock freshness and integrity
bau deps sync --locked                     # require lock is present and current
bau deps sync --frozen                     # --locked --offline
```

### Integrity verification

`bau deps verify` checks:

1. Lock file exists and parses correctly (version 2)
2. `requirementsHash` matches the current config (lock is not stale)
3. Every non-optional direct dependency appears in the lock
4. Every materialized package's on-disk checksum matches the lock
5. Every materialized Git package's revision matches the lock

### When to commit bau.lock

Always commit `bau.lock` for applications. For libraries, committing it is
recommended but not required — it ensures contributors and CI use the same
dependency versions. Without a committed lock, each checkout may resolve
different versions.

---

## Dependency Governance

Governance policies are enforced by `bau deps verify` and configured in
`[governance]`:

```toml
[governance]
blocked = ["malicious_pkg", "known_vulnerable"]
trusted = ["parsetoml", "jsony", "sqlite"]
minimumReleaseAgeHours = 24
```

### Blocked dependencies

`blocked` is a deny-list. Any dependency named in this list causes verification
to fail. Use it to prevent known-problematic packages from entering the
dependency graph, even transitively.

### Trusted dependencies

`trusted` is an allow-list. When non-empty, **every** dependency must appear in
this list. This is "zero-trust" mode: only explicitly reviewed and approved
packages are permitted.

### Minimum release age

`minimumReleaseAgeHours` prevents supply-chain attacks from newly published
package versions. The policy uses each package's `lockedAt` timestamp from
`bau.lock` — which is only updated when the package's content actually changes
(same revision + checksum preserves the old timestamp).

For non-path dependencies, Bau verifies that `now - lockedAt >=
minimumReleaseAgeHours * 3600`. Path dependencies are exempt (they are local code).

Example: if `parsetoml` 0.6.1 was first locked 12 hours ago and
`minimumReleaseAgeHours` is 24, verification fails with a message indicating
how many hours remain.

---

## Documentation Generation

Bau generates API documentation using Nim's built-in `nim doc` tool,
orchestrated through the `[docs]` configuration section.

### Configuration

```toml
[docs]
outDir = "docs/api"
entrypoints = ["src/myapp.nim"]
include = ["src/**/*.nim"]
exclude = ["src/**/private/**", "src/internal/**"]
flags = ["--docCmd:skip"]           # extra nimdoc flags
project = true                      # pass Nimdoc --project
index = true                        # generate theindex.html
runExamples = true                   # compile and run code examples
includePrivate = false               # include non-public modules
sourceUrl = "https://github.com/user/myapp/blob/main"
```

### Module discovery

Bau discovers modules to document by:

1. Starting from configured `entrypoints` (or defaults: build main, package
   root, target mains)
2. Applying `include` glob patterns (default: all `.nim` files in `src/`)
3. Filtering by `exclude` glob patterns (default: `private/`, `internal/` paths)
4. Deduplicating by absolute path

Conventional `private/` and `internal/` directories are skipped by default,
following Nim ecosystem conventions.

### Usage

```sh
bau doc                                   # generate docs to [docs].outDir
bau doc --open                            # open in browser after generation
bau doc --out-dir site/api               # custom output directory
bau doc --skip-examples                   # don't compile/run doc examples
bau doc --include-private                 # include private modules
bau doc --no-index                        # skip theindex.html generation
bau doc --entry src/main.nim --entry src/cli.nim   # explicit entrypoints
```

### Workspace documentation

In a workspace, `bau doc` runs documentation generation for each member and
produces a combined JSON report with per-member metadata, diagnostics, and
generated file lists.

---

## Command Reference

### Global options

These work with every command:

| Flag | Description |
|---|---|
| `--profile`, `-p <name>` | Build profile (default: `dev`) |
| `--jobs`, `-j <n>` | Parallel jobs forwarded as `--parallelBuild:<n>` to Nim |
| `--verbose`, `-v` | Verbose output (prints full Nim command lines) |
| `--quiet`, `-q` | Minimal output (warnings and errors only) |
| `--color <mode>` | `auto`, `always`, or `never` |
| `--force`, `-f` | Force overwrite or bypass cache where supported |
| `--dry-run`, `-n` | Show what would happen without executing |
| `--keep-going` | Continue independent tasks after a dependency fails |
| `--features <a,b>` | Enable specific feature flags |
| `--all-features` | Enable all declared features |
| `--no-default-features` | Do not enable the default feature set |
| `--json` | Output in JSON format |
| `--format <mode>` | Output format: `dot`, `json` |
| `--format-version <n>` | Pin JSON schema version |
| `--changed` | Operate only on changed files |
| `--watch`, `-w` | Watch files and rebuild on changes |
| `--timings` | Show per-step timing |
| `--locked` | Require up-to-date lockfile |
| `--offline` | No network operations |
| `--frozen` | `--locked --offline` |
| `--install-dir <dir>` | Override `[install].dir` for install/update/uninstall |
| `--update` | Update instead of install for `bau install` |
| `--remove` | Remove instead of install for `bau install` |

### `bau build [target]`

Compile the project. Without a target name, builds the default target from
`[build]`. In a workspace, builds the default members.

### `bau run [target] [-- args]`

Build and run. Arguments after `--` are passed to the binary.

### `bau install [target]`

Build and install a binary target. Without a target name, installs the default
`[build]` target. `--all-targets` installs every configured binary target.
Use `--install-dir <dir>` to override `[install].dir` for this invocation.

`bau install` fails if the destination binary already exists. Use
`bau install --update`, `bau update`, or `--force` when replacing an existing
binary is intentional.

### `bau update [target]`

Build and replace an installed binary target. This is equivalent to
`bau install --update [target]` and fails if the binary is not already installed,
unless `--force` is passed.

### `bau uninstall [target]`

Remove an installed binary target. This is equivalent to
`bau install --remove [target]`. Use `--all-targets` to remove every configured
binary target.

### `bau test [filter]`

Build and run tests. Optional filter string matches test file names.
`--changed` runs only tests affected by current changes.

### `bau check`

Type-check with `nim check`. Does not produce binaries. `--all-targets` checks
every configured target.

### `bau doc`

Generate API documentation. See [Documentation Generation](#documentation-generation).

### `bau fmt`

Format all `.nim` files in `src/` with `nimpretty`.

### `bau lint`

Check code style with `nim check --styleCheck:error`.

### `bau ci`

Run `fmt`, `lint`, and `test` sequentially. Fails on the first error.

### `bau clean`

Remove `build/`.

### `bau shell`

Open a shell with build environment variables set (project dir, profile,
features, search paths). Useful for running Nim commands manually with the same
environment Bau uses.

### `bau shell-init [shell]`

Write a guarded startup snippet for the selected shell so `~/.bau/bin` is added
only when the shell's `PATH` does not already contain it. Files already
mentioning `.bau/bin` are left unchanged. Without an argument, Bau uses
`$SHELL`; supported shells are `bash`, `zsh`, `fish`, and `sh`.

### `bau deps [sync]`

Fetch and materialize all enabled dependencies via Atlas. Add `--locked` to
require an up-to-date lockfile, `--offline` to skip network access, or
`--frozen` for both.

### `bau deps lock`

Write `bau.lock` with the resolved dependency graph. Scans materialized
dependencies, extracts metadata from `.nimble` files and Atlas bridge data,
computes checksums, and writes the lock as TOML.

### `bau deps update <dep> --precise <rev>`

Check out an exact Git revision for a materialized dependency.

### `bau deps verify`

Enforce dependency policies: blocked/trusted lists, lockfile freshness,
checksums, and minimum release age.

### `bau deps vendor`

Copy `deps/` to `vendor/` with a checksum manifest.

### `bau deps patch <dep> --path <path>`

Add a `[patch]` entry overriding a dependency with a local path.

### `bau add <dep> [options]`

Add a dependency to `bau.toml`. Supports `--version`, `--git`, `--tag`,
`--branch`, `--rev`, `--path`, `--registry`, `--optional`.

### `bau remove <dep>`

Remove a dependency from `bau.toml`.

### `bau outdated`

Show dependencies with newer versions available.

### `bau tree`

Display the dependency tree.

### `bau metadata`

Print resolved project metadata (package info, dependencies, profiles, targets,
tasks, features). Use `--json` for machine-readable output.

### `bau graph`

Print dependency or target graph. `--format dot` for Graphviz, `--format json`
for structured output.

### `bau query deps <target>`

List all dependencies for a target (resolved from lockfile then config).

### `bau query why <dep>`

Explain why a specific dependency is in the graph — which direct dependency or
feature pulled it in, and whether it is optional.

### `bau affected list`

List changed files and affected targets, tests, and tasks since a Git ref
(default: `HEAD`). Use `--since <ref>` for a different base.

### `bau affected build`

Build only targets whose main file or dependencies changed.

### `bau affected test`

Test only test files whose module or its dependencies changed.

### `bau affected check`

Check only targets affected by changes.

### `bau tailor`

Scan Nim sources for modules with `isMainModule` that are not declared as
targets. `--check` exits non-zero if any are found. `--write` appends them to
`bau.toml`.

### `bau cache list`

List all cache entries across all tasks.

### `bau cache explain <task>`

Show the cache key, local hit/miss status, remote hit/miss/error status, and
restored output paths. Use `--json` for machine-readable output.

### `bau cache clean`

Remove all task cache entries.

### `bau package --list`

List files that would be included in a Nimble package. Use `--dry-run` for
validation without publishing.

### `bau bump <major|minor|patch>`

Increment `[package].version` using SemVer rules. `major` increments the first
component and resets minor/patch, `minor` increments the second component and
resets patch, and `patch` increments the third component. The selector can also
be passed as `--major`, `--minor`, or `--patch`. If `<package>.nimble` exists,
Bau updates its top-level `version =` assignment too. Use `--dry-run` to print
the planned change without writing.

### `bau publish`

Publish to the Nimble registry. `--dry-run` performs full local validation and
prints the generated `.nimble` file content without network access.

### `bau compile-commands`

Generate `compile_commands.json` for LSP editors. Honors profile, feature, and
job settings. The output is target-aware: it includes compilation commands for
every source file under `src/` and `tests/` with the correct profile flags and
search paths.

### `bau doctor`

Check the configured toolchain. Verifies that required tools (Nim, Atlas) are
installed and meet minimum version constraints from `[toolchain]`.

### `bau env`

Print the resolved build environment (search paths, profile flags, feature
defines). Use `--json` for machine-readable output.

### `bau task <name>`

Run a custom task defined in `[[tasks]]`. The task's dependencies are executed
first (in topological order). Cache is checked before execution.

### `bau init [name]`

Initialize `bau.toml` in the current directory. Supports `--bin`, `--lib`,
`--name`, `--version`, `--description`, `--license`, `--edition`.

### `bau new <path>`

Create a new project directory with `bau.toml` and source scaffold. Use
`--lib` for a library project.

### `bau convert [path|file]`

Convert an existing `.nimble` project to `bau.toml`. With no argument, Bau
converts the only `.nimble` file in the current directory. Pass a directory or a
specific `.nimble` file for explicit selection. `--dry-run` prints generated
TOML without writing, `--json` prints the conversion report, and `--force`
overwrites an existing `bau.toml`.

### `bau explain`

Show what changed since the last build by comparing stored and fresh
fingerprints across all 9 dimensions.

### `bau version`

Print the Bau version.

### Plugins

Any executable named `bau-<name>` on `$PATH` is discovered as a `bau <name>`
subcommand. For example, an executable called `bau-deploy` becomes `bau deploy`.

### Custom tasks

Define tasks in `bau.toml`:

```toml
[[tasks]]
name = "bench"
cmd = "nim r -d:release benchmarks/bench.nim"
description = "Run benchmarks"
deps = ["build"]                    # run "build" task first
inputs = ["benchmarks/bench.nim"]
outputs = ["build/bench-results.json"]
cache = true
cwd = "."
shell = "bash"
envInputs = ["ITERATIONS"]
requiredFeatures = ["bench"]
tags = ["performance"]
```

Tasks support:
- `deps` — other task names that must complete first (topological order with
  cycle detection)
- `inputs` / `outputs` — file globs for caching and dependency tracking
- `cache` — force-enable caching even without inputs/outputs
- `cwd` — working directory override
- `shell` — shell to use (defaults to system shell on POSIX, cmd on Windows)
- `envInputs` — environment variables whose values become part of the cache key
- `requiredFeatures` — feature flags needed for this task
- `tags` — arbitrary labels for filtering

The task system uses depth-first traversal with cycle detection via a visiting
set. Failed dependencies propagate upward (preventing dependents from running),
unless `--keep-going` is set, in which case independent sibling tasks continue.

---

## MCP Server

Bau includes an embedded MCP (Model Context Protocol) server that exposes build
operations to AI agents. It communicates over stdin/stdout using JSON-RPC 2.0
with `Content-Length` framing, per the MCP specification (protocol version
`2024-11-05`).

### Starting the server

```sh
bau mcp
# or equivalently:
bau --mcp
```

The server runs an event loop that reads JSON-RPC requests from stdin, executes
the corresponding Bau operation via the same `ops.nim` layer used by the CLI,
and writes JSON-RPC responses to stdout.

### Configuring with Claude Code

Add to your Claude Code MCP configuration (`~/.claude/settings.json` or
`.claude/settings.local.json`):

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

The server discovers the project root from the working directory, so it should
be launched from your project directory.

### Tools

The MCP server exposes 20 tools. Every tool maps 1:1 to a Bau CLI command via
the operation layer. They produce the same JSON output as `bau <command>
--json`.

#### Build tools

| Tool | CLI Equivalent | Key Parameters |
|---|---|---|
| `bau_build` | `bau build` | `profile`, `verbose` |
| `bau_run` | `bau run` | `profile`, `args` (string array) |
| `bau_test` | `bau test` | `filter` |
| `bau_check` | `bau check` | (none) |
| `bau_clean` | `bau clean` | (none) |
| `bau_doc` | `bau doc` | `profile`, `outDir`, `entrypoints`, `skipExamples`, `includePrivate`, `noIndex` |
| `bau_install` | `bau install`/`bau update`/`bau uninstall` | `action`, `target`, `profile`, `installDir`, `allTargets`, `force`, `dryRun` |
| `bau_fmt` | `bau fmt` | (none) |

#### Dependency tools

| Tool | CLI Equivalent | Key Parameters |
|---|---|---|
| `bau_deps` | `bau deps` | `update` (default: false) |
| `bau_add` | `bau add` | `name` (required), `version`, `git`, `tag`, `branch`, `rev`, `path`, `registry`, `optional` |
| `bau_remove` | `bau remove` | `name` (required) |
| `bau_deps_verify` | `bau deps verify` | (none) |

#### Introspection tools

| Tool | CLI Equivalent | Key Parameters |
|---|---|---|
| `bau_metadata` | `bau metadata --json` | (none) |
| `bau_graph` | `bau graph --format json` | (none) |
| `bau_query` | `bau query` | `kind` (`"deps"` or `"why"`), `name` |
| `bau_affected` | `bau affected list --json` | `since` (default: `"HEAD"`) |
| `bau_explain` | `bau explain` | `profile` |
| `bau_cache_explain` | `bau cache explain --json` | `task` (required), `profile` |
| `bau_compile_commands` | `bau compile-commands` | `profile`, `features`, `allFeatures`, `noDefaultFeatures`, `jobs` |

#### Scaffolding

| Tool | CLI Equivalent | Key Parameters |
|---|---|---|
| `bau_init` | `bau init` | `name` (required), `kind` (`"bin"` or `"lib"`), `dir` |
| `bau_convert` | `bau convert` | `path`, `dryRun` (default: true), `force` |

### Resources

Resources use the `bau://` URI scheme and return JSON. They provide read-only
access to project state:

| URI | Description |
|---|---|
| `bau://config` | Merged effective configuration (all layers combined) |
| `bau://targets` | Build targets with profiles, source files, and feature requirements |
| `bau://deps` | Full dependency tree with versions, sources, patches, and resolved status |
| `bau://tasks` | Custom tasks and build scripts with their configurations |
| `bau://status` | Per-target build status (dirty/clean fingerprints) |

### Protocol examples

**Build the project:**
```json
→ {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "bau_build",
      "arguments": { "profile": "release" }
    }
  }

← {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
      "content": [{ "type": "text", "text": "{\"ok\":true,\"output\":\"...\"}" }]
    }
  }
```

**Read dependency tree:**
```json
→ {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "resources/read",
    "params": { "uri": "bau://deps" }
  }

← {
    "jsonrpc": "2.0",
    "id": 2,
    "result": {
      "contents": [{
        "uri": "bau://deps",
        "mimeType": "application/json",
        "text": "{\"dependencies\":[...],\"tree\":{...}}"
      }]
    }
  }
```

**Add a dependency:**
```json
→ {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "bau_add",
      "arguments": {
        "name": "parsetoml",
        "version": ">=0.6.0"
      }
    }
  }
```

**Check what changed:**
```json
→ {
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "bau_affected",
      "arguments": { "since": "origin/main" }
    }
  }
```

### Error handling

Operation errors are reported with `isError: true` in the result (not as
JSON-RPC errors). Protocol-level errors (unknown method, invalid parameters)
use standard JSON-RPC error codes. Notifications (methods starting with
`notifications/`) are silently acknowledged.

### Architecture note

The MCP server and CLI share the same `ops.nim` operation layer. The only
difference is I/O encoding: the CLI formats `OperationResult` for human
readability, while the MCP server returns `OperationResult.json` directly. This
means there is no semantic difference between `bau build` and calling
`bau_build` via MCP — they execute identical code paths.

---

## Configuration Reference

### `[package]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Package name (used for binary output and nimble compatibility) |
| `version` | string | Semantic version |
| `description` | string | Short description |
| `license` | string | SPDX license identifier |
| `edition` | string | Bau configuration edition (e.g., `"2026"`) |

### `[build]`

| Field | Type | Description |
|---|---|---|
| `kind` | string | `"bin"` or `"lib"` |
| `source` | string | Source directory (default: `"src"`) |
| `main` | string | Entry point `.nim` file |
| `output` | string | Output binary name (default: package name) |

### `[[targets]]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Target name (used in `bau build <name>`) |
| `kind` | string | `"bin"` or `"lib"` |
| `main` | string | Entry point file path |
| `profile` | string | Profile override (default: uses global profile) |
| `requiredFeatures` | string[] | Features that must be enabled for this target |
| `tags` | string[] | Arbitrary tags for filtering |

### `[profile.<name>]`

| Field | Type | Description |
|---|---|---|
| `extends` | string | Parent profile name (recursive inheritance) |
| `flags` | string[] | Nim compiler flags |
| `gc` | string | Garbage collector: `"orc"`, `"refc"`, `"arc"`, `"none"` |
| `defines` | table | Preprocessor defines (`-d:key=value`) |
| `nim` | string | Nim version constraint for this profile |

### `[dependencies]`

Each key is a package name. Values can be:

- **String**: Version constraint (e.g., `">=1.0.0"`)
- **Inline table**: `{ version = ">=1.0", optional = true, git = "..." }`

| Field | Type | Description |
|---|---|---|
| `version` | string | Version constraint |
| `git` | string | Git repository URL |
| `tag` | string | Git tag |
| `branch` | string | Git branch |
| `rev` | string | Exact Git revision |
| `path` | string | Local filesystem path |
| `registry` | string | Registry name |
| `optional` | bool | Only enabled when a feature activates it |

### `[[tasks]]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Task name (used in `bau task <name>`) |
| `cmd` | string | Shell command or NimScript path |
| `description` | string | Human-readable description |
| `deps` | string[] | Prerequisite task names |
| `inputs` | string[] | File glob patterns for caching and change detection |
| `outputs` | string[] | File paths the task produces |
| `cwd` | string | Working directory override |
| `shell` | string | Shell override (e.g., `"bash"`, `"fish"`) |
| `envInputs` | string[] | Env vars whose values are part of the cache key |
| `cache` | bool | Force-enable caching (default: auto-detected from inputs/outputs) |
| `requiredFeatures` | string[] | Features needed for this task |
| `tags` | string[] | Arbitrary tags |

### `[[buildScripts]]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Script name (for logging and cache identity) |
| `cmd` | string | Command to execute |
| `deps` | string[] | Script dependencies (not task deps — currently unused) |
| `inputs` | string[] | Files the script reads |
| `outputs` | string[] | Files the script generates |
| `envInputs` | string[] | Env vars that affect the script's output |

### `[features]`

| Field | Type | Description |
|---|---|---|
| `default` | string[] | Features enabled by default |
| `<name>` | string[] | Items this feature enables: other features, `"dep:<name>"`, or bare dep names |

### `[docs]`

| Field | Type | Description |
|---|---|---|
| `outDir` | string | Output directory (default: `"docs"`) |
| `entrypoints` | string[] | Entry module files for documentation |
| `include` | string[] | Glob patterns for module inclusion |
| `exclude` | string[] | Glob patterns for module exclusion |
| `flags` | string[] | Extra nimdoc flags |
| `project` | bool | Pass Nimdoc's `--project` flag |
| `index` | bool | Generate index/search files |
| `runExamples` | bool | Compile and run doc code examples |
| `includePrivate` | bool | Include non-public modules |
| `sourceUrl` | string | Repository source URL for "See source" links |

### `[cache]`

| Field | Type | Description |
|---|---|---|
| `dir` | string | Local cache directory |
| `read` | bool | Read from cache (default: `true`) |
| `write` | bool | Write to cache (default: `true`) |
| `remote` | string | Remote cache URL (`file://` or `https://`) |

### `[install]`

| Field | Type | Description |
|---|---|---|
| `dir` | string | Directory for `bau install`, `bau update`, and `bau uninstall` |

When `dir` is not set, Bau uses `~/.bau/bin`.

### `[governance]`

| Field | Type | Description |
|---|---|---|
| `blocked` | string[] | Forbidden dependency names |
| `trusted` | string[] | Allowlisted dependency names (when set, only these are allowed) |
| `minimumReleaseAgeHours` | int | Minimum age in hours before a resolved version is accepted |

### `[toolchain]`

| Field | Type | Description |
|---|---|---|
| `nim` | string | Minimum Nim version (e.g., `">=2.2"`) |
| `atlas` | string | Minimum Atlas version (e.g., `">=0.8"`) |

### `[patch]`

Each key is a dependency name, value is a partial `DepInfo` table or string:

```toml
[patch]
parsetoml = { path = "../parsetoml" }
```

### `[source.<name>]`

| Field | Type | Description |
|---|---|---|
| `registry` | string | Registry URL |
| `directory` | string | Vendor directory path |
| `localRegistry` | string | Local registry mirror path |
| `git` | string | Git repository URL |
| `replaceWith` | string | Name of another source to use instead (supports chaining) |

### `[catalog]` / `[workspace.catalog.<name>]`

Version catalogs for centralized version management:

```toml
[catalog]
parsetoml = ">=0.6.0"

[workspace.catalogs.stable]
parsetoml = "0.6.1"
```

Referenced from dependencies as `"catalog:"` or `"catalog:stable"`.

### `[workspace]`

| Field | Type | Description |
|---|---|---|
| `members` | string[] | Member project paths |
| `defaultMembers` | string[] | Subset built by default |
| `exclude` | string[] | Paths to exclude |
