# Bau Command Recipes

Load this reference when a task needs a concrete Bau command sequence. Keep
commands in the user's project root unless a workflow explicitly changes
directory.

## New Project

```sh
bau new myapp
cd myapp
bau deps sync
bau check
bau test
bau run
```

```sh
bau new mylib --lib
cd mylib
bau deps sync
bau test
bau doc --open
```

## Convert From Nimble

```sh
git status --short
bau convert --dry-run
bau convert
bau deps sync
bau tailor --check
bau check --all-targets
bau test
```

If missing targets are reported:

```sh
bau tailor --write
bau check --all-targets
bau test
```

## Local Development

```sh
bau deps sync --locked
bau doctor
bau check
bau test
bau run -- --help
```

```sh
bau build --profile release
bau run --profile release -- --version
```

## Features

```sh
bau deps sync --features db
bau build --features db
bau test --features db
bau build --no-default-features --features db
bau build --all-features
```

## Affected Work

```sh
bau affected list --since origin/main
bau affected check --since origin/main
bau affected test --since origin/main
```

## Dependency Add/Update

```sh
bau add jsony --version ">=1.1.0"
bau deps sync
bau deps verify
bau test
git diff -- bau.toml bau.lock
```

```sh
git switch -c deps/update
bau deps update
bau tree
bau deps verify
bau check --all-targets
bau test
git diff -- bau.lock
```

```sh
bau deps update mylib --precise abc123def456
bau deps verify
bau test
```

## Offline, Locked, Vendor

```sh
bau deps sync --locked
bau deps sync --offline
bau deps sync --frozen
```

`--frozen` means locked plus offline.

```sh
bau deps sync --locked
bau deps vendor
bau deps verify
```

## Documentation

```sh
bau doc
bau doc --open
bau doc --out-dir site/api
bau doc --skip-examples
bau doc --include-private
bau doc --no-index
```

## Task Cache

```sh
bau task site
bau cache list
bau cache explain site
bau cache explain site --json
bau cache clean
```

## Editor/LSP

```sh
bau compile-commands --profile dev
bau compile-commands --profile release --features db --jobs 8
```

## MCP

Claude Code:

```sh
claude mcp add --transport stdio --scope project bau -- bau mcp
claude mcp list
```

`.mcp.json`:

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

## CI

```sh
bau deps sync --locked
bau deps verify
bau ci
bau build --profile release
bau doc
bau package --list --dry-run
```

Offline CI:

```sh
bau deps sync --frozen
bau deps verify
bau ci
```

## Package And Publish

```sh
bau deps sync --locked
bau deps verify
bau check --all-targets
bau test
bau doc
bau package --list --dry-run
bau publish --dry-run
```

```sh
bau publish
```

Real publication rejects local path dependencies and `[patch]` entries.
