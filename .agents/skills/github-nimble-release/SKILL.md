---
name: github-nimble-release
description: Prepare and perform proper releases for Nim packages that publish both a GitHub release and a Nimble package. Use when the user asks to cut, prepare, validate, tag, publish, or troubleshoot a GitHub + Nimble release, especially in projects with bau.toml, .nimble files, bau.lock, Git tags, gh CLI, or nimble publish.
---

# GitHub + Nimble Release

Use this skill to make release work boring, reproducible, and hard to regret.
Treat `git push`, `gh release create`, and `bau publish` / `nimble publish` as
external publishing actions: run dry-runs and show the exact planned commands
before doing them unless the user has already explicitly asked to publish.

## First Checks

1. Confirm the project shape and release tools:

   ```sh
   pwd
   rg --files -g 'bau.toml' -g '*.nimble' -g 'CHANGELOG*' -g 'Readme*'
   git status --short
   git tag --list 'v*' --sort=-version:refname | head -20
   command -v gh || true
   command -v nimble || true
   ```

2. If `bau.toml` exists, prefer Bau commands over raw Nim/Nimble commands:

   ```sh
   sed -n '1,220p' bau.toml
   bau metadata --json
   ```

3. Do not continue to a real release from a dirty worktree unless every change
   is intentional and included in the release commit. Preserve unrelated user
   edits.

## Version And Metadata

- Decide the SemVer bump from user intent and the changes since the last tag.
- Keep `bau.toml`, any `<package>.nimble`, docs, and release notes consistent.
- In Bau projects, use:

  ```sh
  bau bump --dry-run --patch
  bau bump --patch
  ```

  Use `--major` or `--minor` when appropriate.

- Check for release blockers:
  - no local path dependencies in `[dependencies]`;
  - no `[patch]` entries for a public publish;
  - no uncommitted generated metadata surprises;
  - repository/homepage/license/authors are present for public packages.

## Preflight Gate

Run the strongest local gate practical for the project:

```sh
bau deps sync --locked
bau deps verify
bau doctor
bau check --all-targets
bau test
bau doc
bau package --list --dry-run
bau publish --dry-run
bau build --profile release
```

If the project has no Bau config, adapt with raw Nim/Nimble commands, but keep
the same intent: locked deps, tests, docs/package validation, and a release
build. If any preflight fails, fix that first; do not tag around a failing gate.

## Release Notes

Build notes from the previous release tag:

```sh
git log <previous-tag>..HEAD --oneline --decorate
git diff --stat <previous-tag>..HEAD
```

Prefer a short, human release note with:
- headline summary;
- breaking changes or migration notes;
- notable features/fixes;
- verification commands that passed.

Use the project changelog if it exists. If not, create a temporary notes file
for `gh release create --notes-file`; do not invent a permanent changelog
unless asked.

## Commit, Tag, And Publish

Use this order for a normal non-draft release:

1. Commit the release changes:

   ```sh
   git diff
   git add bau.toml *.nimble CHANGELOG* Readme.md docs bau.lock
   git commit -m "Release vX.Y.Z"
   ```

   Adjust the staged paths to the actual changed files.

2. Create an annotated tag:

   ```sh
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   ```

3. Final smoke check from the tagged commit:

   ```sh
   git status --short
   bau publish --dry-run
   ```

4. Push the release commit and tag:

   ```sh
   git push origin HEAD
   git push origin vX.Y.Z
   ```

5. Publish to Nimble:

   ```sh
   bau publish
   ```

   In non-Bau projects use `nimble publish` after equivalent dry-run checks.

6. Create the GitHub release:

   ```sh
   gh release create vX.Y.Z \
     --title "vX.Y.Z" \
     --notes-file /path/to/release-notes.md
   ```

For higher caution, create a GitHub draft release first, publish to Nimble, then
undraft or publish the GitHub release after Nimble succeeds.

## Verification After Publishing

After publishing:

```sh
gh release view vX.Y.Z
git ls-remote --tags origin 'vX.Y.Z'
nimble search <package>
```

If the package is installable from Nimble in a fresh temp directory, verify it:

```sh
tmp=$(mktemp -d)
cd "$tmp"
nimble install <package>@X.Y.Z
```

Report the release URL, Nimble package/version, tag, commit SHA, and verification
commands. If something failed after a public action, describe what was published
and what remains to repair; do not rewrite public tags without explicit user
approval.

## Common Repairs

- Dry-run fails because of local paths or patches: remove them or convert them
  to registry dependencies before publishing.
- Version mismatch: update `bau.toml` and the `.nimble` file together, then
  rerun the full preflight.
- Tag exists locally but not remotely: verify the commit, then push the tag.
- GitHub release exists but Nimble publish failed: fix the publish blocker and
  republish the same version only if the package was not accepted by Nimble.
  Otherwise bump to a new version.
- Nimble accepted a bad release: assume it is immutable for consumers; cut a
  follow-up version rather than trying to hide history.
