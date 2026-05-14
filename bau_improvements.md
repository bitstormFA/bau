# Bau Improvement Suggestions From The Rew Migration

These notes come from migrating the `rew` project build orchestration from
Nimble tasks to Bau. The overall experience was positive: Bau handled package
metadata, explicit targets, profiles, lockfile generation, and task graphs
cleanly. The main friction came from real-world Nimble tasks acting as small
CLIs and from a large project test suite with its own runner semantics.

## Highest Impact

### 1. Task Argument Passthrough

The biggest migration friction was that Bau tasks cannot naturally do:

```bash
bau task fetch -- cpu
```

Rew had several Nimble tasks that forwarded `commandLineParams`, such as
`fetch`, `hfFetch`, `buildPlugin`, and `openxla`. During the migration, these
had to become runnable targets instead:

```bash
bau run fetch -- cpu
bau run buildPlugin -- cpu
bau run openxla -- list
```

Suggested improvements:

- Support `bau task <name> -- <args...>`.
- Expose args through interpolation, for example:
  `cmd = "nim c -r tools/fetch.nim -- {args}"`.
- Or expose args as environment variables such as `BAU_TASK_ARGS`,
  `BAU_TASK_ARG_0`, etc.
- Add `acceptArgs = true` so accidental args remain errors by default.

### 2. Configurable Test Runner And Test Matrix

Rew already had `tests/all.nim`, but Bau only auto-detects `tests/tester.nim`.
I added `tests/tester.nim` solely as a Bau bridge. Rew's canonical test command
also runs three configurations: debug, release, and danger.

Suggested configuration:

```toml
[test]
runner = "tests/all.nim"
profiles = ["dev", "release", "danger"]
recursive = true
exclude = ["thelper.nim"]
```

This would let `bau test` report the real matrix instead of reporting one
runner file as passed while that runner internally executed the full suite.

### 3. Live Output Mode For Long Test Runs

`bau test` captured the runner output. For a large suite, that meant several
minutes of silence unless I checked processes manually. Capturing output is good
for small tests, but rough for long-running project suites.

Suggested improvements:

- Add `bau test --show-output=auto|always|never`.
- Stream output live for configured runners.
- Print periodic progress for long-running tests.
- Keep failure summaries concise, but make active progress visible.

### 4. Command-Specific Help For Tasks

`bau task --help` tried to run a task named `--help`. That was surprising.

Suggested improvements:

- `bau task --help` should show task-command help.
- `bau task --list` should list tasks with descriptions.
- `bau task <name> --help` should show task metadata: deps, command,
  inputs/outputs, cache state, required features, and description.

### 5. Decouple Target Name From Output Binary

In Bau, a target's output name is effectively the target name. That is
convenient until command names and binary names diverge.

Suggested configuration:

```toml
[[targets]]
name = "fetch"
output = "rew_fetch_dev"
main = "tools/fetch.nim"
```

This would also help avoid awkward duplicate/default target situations.

## Build Model Polish

### 6. Include Or Dedupe The Default Target When Explicit Targets Exist

Rew needed an explicit `rew_fetch` target because once `[[targets]]` exist,
`bau build` builds those targets rather than the default `[build]` target. This
also produced duplicate-looking `target:rew_fetch` nodes in `bau graph`.

Suggested improvements:

- Make the default target a named target internally.
- Dedupe graph IDs.
- Add `[build] name = "rew_fetch"` or `includeDefault = true`.

### 7. Target-Specific Source And Path Settings

Rew has package binaries under `src/` and tool entrypoints under `tools/`. Bau
handled this because global `source = "src"` gave the right import path, but
target-level overrides would make this clearer.

Suggested configuration:

```toml
[[targets]]
name = "fetch"
main = "tools/fetch.nim"
source = "tools"
paths = ["src"]
```

### 8. Better Nimble Conversion For Dynamic Tasks

`bau convert` correctly warned about dynamic NimScript, but the generated
result still required manual interpretation. It skipped common patterns such as
"compile this Nim tool and forward args".

Suggested improvements:

- Recognize simple `commandLineParams` forwarding patterns.
- Emit candidate runnable targets for forwarded-arg tasks.
- Emit commented TODO stubs in `bau.toml`.
- Split multi-`exec` Nimble tasks into dependency tasks instead of one command
  joined with `&&`.

### 9. Task Aliases And Built-In Command Conflicts

Rew has an architectural lint task. Bau also has built-in `bau lint` for style,
so the project command became `bau task lint`.

Suggested configuration:

```toml
[aliases]
lint = "task lint"
ci = "task ci"
```

Or make CI configurable:

```toml
[ci]
steps = ["task lint", "test"]
```

### 10. First-Class Profile-Aware Tasks

`bau task asan` had to spell out:

```bash
nim c -d:addressSanitizer -r tests/all.nim
```

Even though an `asan` profile was defined.

Suggested configuration:

```toml
[[tasks]]
name = "asan"
command = "test"
profile = "asan"
```

## UX And Diagnostics

### 11. Graph JSON Should Never Emit Duplicate IDs

`bau graph --format json` emitted duplicate `target:rew_fetch` IDs for the
default target plus the explicit target. Graph consumers generally assume IDs
are unique.

### 12. `bau test` Should Communicate Nested Runner Semantics

If a runner is used, saying `tester.nim passed` is technically true but hides
what actually ran. Configured runners could declare a display name or matrix.

### 13. Task Discovery Should Include Descriptions Prominently

Tasks are readable in TOML, but during migration humans need quick discovery:

```bash
bau task --list
```

With task names, descriptions, deps, and whether the task is cacheable.

### 14. Better "Next Command" Hints

After `bau convert --dry-run` warnings, Bau could suggest concrete migration
paths:

- "This task forwards CLI args; consider a runnable target."
- "This task has multiple execs; consider task deps."
- "This task invokes tests in several modes; consider `[test].profiles`."

### 15. Document Common Migration Patterns

A workflow guide section for common Nimble task patterns would help:

- Nimble `task fetch`: use `[[targets]]` plus `bau run fetch -- ...`.
- Nimble test matrix: use `tests/tester.nim` or future `[test]`.
- Nimble lint pipeline: use task dependencies.
- Nimble tool wrappers: use runnable targets when args are needed.

## Theme

Bau already works well as declarative build metadata. The next step is making
the "Nimble tasks as project automation" migration smoother. First-class task
args, configurable test matrices, task listing/help, aliases, and better
conversion hints would make migrations like `rew` much cleaner.
