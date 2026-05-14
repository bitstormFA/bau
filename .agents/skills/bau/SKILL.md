---
name: bau
description: Use Bau, the Nim build tool, for project setup, Nimble migration, dependency management, reproducible builds, tests, docs, MCP integration, CI, packaging, deployment, and publication. Trigger when working in a Nim repository with bau.toml, creating or converting a Bau project, updating bau.lock/deps, running Bau CLI commands, configuring Bau MCP for Claude Code or VS Code Copilot, or explaining Bau workflows.
---

# Bau

Use Bau as the orchestration layer for Nim projects when `bau.toml` is present
or when the user wants to adopt Bau. Prefer Bau commands over direct `nim`,
`nimble`, or `atlas` commands unless the task is specifically about internals or
bootstrapping Bau itself.

For richer task examples, read `docs/workflow-guide.md` if it exists. For
complete command/config reference, read `docs/user-guide.md`. For quick command
recipes, read `references/command-recipes.md`.

## First Moves

1. Check the project shape:

   ```sh
   pwd
   rg --files -g 'bau.toml' -g '*.nimble' -g 'docs/workflow-guide.md' -g 'docs/user-guide.md'
   git status --short
   ```

2. If `bau.toml` exists, load context from it before changing behavior:

   ```sh
   sed -n '1,240p' bau.toml
   bau metadata --json
   ```

3. If there are uncommitted changes, preserve them. Do not revert user edits.
4. If dependencies are needed, prefer `bau deps sync --locked`; use plain
   `bau deps sync` only when creating or intentionally refreshing `bau.lock`.

## Core Model

- `bau.toml` declares package metadata, build targets, profiles, dependencies,
  features, docs, tasks, cache, toolchain, and policy.
- `bau.lock` records the resolved dependency graph, exact versions or Git
  revisions, source identity, dependency edges, and checksums. Commit it with
  dependency changes.
- `deps/` is materialized by Atlas; Bau delegates fetching/resolution to Atlas
  and then locks/verifies what is present.
- `build/` holds compiled outputs, fingerprints, task cache entries, package
  manifests, and generated build artifacts.
- `bau.local.toml` is local-only. Avoid documenting it as a team requirement.

Reproducibility depends on both dependency locks and build fingerprints. Use
`--locked` in CI and `--frozen` for locked plus offline verification.

## Project Setup

Create a binary:

```sh
bau new myapp
cd myapp
bau deps sync
bau check
bau test
```

Create a library:

```sh
bau new mylib --lib
cd mylib
bau deps sync
bau test
bau doc
```

For existing directories:

```sh
bau init
bau init myapp --bin --version 0.1.0 --description "A Nim app" --license MIT
```

After setup, encourage committing `bau.toml`, `bau.lock`, `src/`, and `tests/`.

## Nimble Migration

Use a reviewable migration loop:

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
bau test
```

Remember that conversion is static: Bau converts deterministic Nimble metadata
and literal tasks/hooks, but it does not execute NimScript control flow. Model
dynamic Nimble behavior explicitly with profiles, features, tasks, or build
scripts.

## Build, Test, And Edit Loop

Default local loop:

```sh
bau deps sync --locked
bau doctor
bau check
bau test
bau run -- --help
```

Release-like checks:

```sh
bau build --profile release
bau run --profile release -- --version
```

Feature checks:

```sh
bau build --features db
bau test --features db
bau build --no-default-features --features db
bau build --all-features
```

Changed-work checks:

```sh
bau affected list --since origin/main
bau affected test --since origin/main
bau affected check --since origin/main
```

Use `bau explain` when an incremental build does or does not rebuild as
expected. Use `bau compile-commands` after changing profiles/features when an
editor or LSP needs exact compiler commands.

## Dependencies

Add and verify a registry dependency:

```sh
bau add jsony --version ">=1.1.0"
bau deps sync
bau deps verify
bau test
git diff -- bau.toml bau.lock
```

Add Git, path, or optional dependencies:

```sh
bau add mylib --git https://github.com/example/mylib --tag v1.2.0
bau add localpkg --path ../localpkg
bau add sqlite --version ">=3.0" --optional
```

Optional dependencies require a feature entry such as:

```toml
[features]
db = ["dep:sqlite"]
```

Update dependencies on a branch:

```sh
bau deps update
bau tree
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

Use `[patch]` or `bau deps patch <dep> --path <path>` for local dependency
experiments. Remove patches and local path dependencies before publishing.

## Docs

Use Bau docs instead of raw `nim doc` so profiles, features, search paths, and
configured entrypoints are applied:

```sh
bau doc
bau doc --open
bau doc --out-dir site/api
bau doc --skip-examples
bau doc --include-private
```

When editing public modules, add or preserve top-level Nim doc comments. Bau
warns when modules lack them.

## Tasks And Cache

Custom tasks live in `[[tasks]]` and run with:

```sh
bau task <name>
bau cache explain <name>
bau cache explain <name> --json
```

A task is cacheable when it declares `inputs` and `outputs`, or sets
`cache = true`. Include environment-sensitive values in `envInputs`.

Use `[[buildScripts]]` only when a pre-build step must affect compilation by
emitting `bau::` directives such as `bau::nim-flag=...`,
`bau::define=...`, or `bau::generated-file=...`.

## MCP Integration

Bau MCP runs over stdio:

```sh
bau mcp
```

Claude Code project setup:

```sh
claude mcp add --transport stdio --scope project bau -- bau mcp
claude mcp list
```

Minimal `.mcp.json`:

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

VS Code Copilot `.vscode/mcp.json`:

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

Tell users that client-side MCP details may change; when accuracy matters, check
the official Claude Code, GitHub Copilot, or VS Code docs.

## CI And Release

Conservative CI gate:

```sh
bau deps sync --locked
bau deps verify
bau ci
bau build --profile release
bau doc
bau package --list --dry-run
```

Hermetic/offline gate:

```sh
bau deps sync --frozen
bau deps verify
bau ci
```

Publication preflight:

```sh
bau deps sync --locked
bau deps verify
bau check --all-targets
bau test
bau doc
bau package --list --dry-run
bau publish --dry-run
```

Real publication uses `nimble publish` through Bau:

```sh
bau publish
```

Do not publish with `[patch]` entries or local path dependencies; Bau rejects
them for real publishes because registries cannot reproduce them.

## Troubleshooting

- Dependency issues: run `bau deps sync --locked`, `bau deps verify`,
  `bau tree`, and `bau query why <dep>`.
- Offline issues: compare `bau deps sync --offline` with
  `bau deps sync --frozen`.
- Unexpected rebuilds: run `bau explain`, then `bau build --verbose` if needed.
- Task cache misses: run `bau cache explain <task> --json`.
- Docs failures: run `bau doc --verbose`, then isolate with
  `bau doc --skip-examples` or `bau doc --include-private`.
- Editor/LSP issues: regenerate `compile_commands.json` with the active profile
  and features.
