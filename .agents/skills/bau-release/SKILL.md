---
name: bau-release
description: Release Bau through the project-local scripts/release.sh workflow. Use when the user asks to prepare, dry-run, validate, cut, publish, troubleshoot, or inspect a Bau release, including GitHub + Nimble releases, version bumps, release notes, tags, release commits, or structured release reports for this repository.
---

# Bau Release

Use `scripts/release.sh` as the source of truth for releases in this repository.
It wraps the GitHub + Nimble release workflow with version updates, docs,
preflight checks, commit/tag creation, dry-run rehearsal, and structured JSON
reporting.

## First Moves

Check the current repository state and script help:

```sh
git status --short
scripts/release.sh --help
```

Default to a dry-run unless the user explicitly asks to publish or execute the
release. A real release requires a clean working tree; do not work around that
guard.

## Select The Version

Use one selector:

```sh
scripts/release.sh --major
scripts/release.sh --minor
scripts/release.sh --patch
scripts/release.sh --version 0.5.0
```

Short positional forms also work: `major`, `minor`, `patch`, or `0.5.0`.

## Dry-Run Release

Run dry-runs before real release attempts:

```sh
scripts/release.sh --version 0.5.0 --dry-run
```

Dry-run mode runs in a temporary clone, performs the real local preparation
steps there, creates a rehearsal commit and tag, validates push commands with
`git push --dry-run`, and avoids publishing to Nimble or GitHub. It prints JSON
and writes the same report under `build/release/.../report.json`.

After a dry-run, summarize:

- `status`, `targetTag`, `releaseCommit`, and `failure`;
- the report path and release-notes path;
- any failed step and its log file;
- the planned external commands.

Useful report query:

```sh
jq '.status, .targetTag, .releaseCommit, .failure' build/release/*/report.json
```

## Real Release

Only run execute mode when the user clearly wants a public release:

```sh
scripts/release.sh --version 0.5.0 --execute
```

Execute mode updates `bau.toml` and `bau.nimble`, refreshes `bau.lock`, runs the
release gate, generates docs and notes, commits `Release vX.Y.Z`, creates an
annotated tag, pushes the commit and tag, publishes with `bau publish`, creates
the GitHub release with `gh release create`, then verifies the remote tag,
GitHub release, and Nimble search.

Use `--github-draft` when the GitHub release should be created as a draft:

```sh
scripts/release.sh --version 0.5.0 --execute --github-draft
```

## Failure Handling

Do not continue manually past a failed release step without understanding it.
Open the `failure.log` path from the JSON report, fix the underlying issue, and
rerun the script.

If a failure happens after an external action in execute mode, report exactly
which public actions succeeded and which remain. Do not delete or rewrite public
tags or releases unless the user explicitly asks for that repair.
