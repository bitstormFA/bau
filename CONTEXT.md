# Bau

Bau is the context for describing Nim projects in a reproducible build system, with clear language around project identity, publishable package metadata, and multi-project coordination.

## Language

**Bau Project**:
A Nim codebase that Bau can build, test, document, or otherwise operate on as one unit.
_Avoid_: Package, repo

**Package**:
The publishable Nim package identity and metadata associated with a Bau Project.
_Avoid_: Project, repo

**Package Contents**:
The selected files that belong to a Package when it is prepared for registry-compatible distribution.
_Avoid_: Package, manifest

**Publication**:
The act of submitting a Package and its Package Contents to a registry-compatible channel.
_Avoid_: Deployment, package

**Workspace**:
A coordination root that selects and configures multiple member Bau Projects.
_Avoid_: Monorepo, multi-package project

**Workspace Member**:
A Bau Project included in a Workspace.
_Avoid_: Package, subproject

**Project Manifest**:
The user-authored declaration of a Bau Project's intended package identity, build shape, dependencies, workflows, and policy.
_Avoid_: Config, configuration file, project file

**Resolved State**:
The recorded outcome of Bau interpreting a Bau Project's declared intent at a point in time.
_Avoid_: Config, generated config

**Bau Output**:
A file or report produced by Bau from a Bau Project.
_Avoid_: State, source

**Command Surface**:
A user-facing way to invoke Bau capabilities.
_Avoid_: Frontend, interface, client

**Operation**:
A Bau capability expressed independently of the Command Surface that invokes it.
_Avoid_: Command handler, MCP tool

**Introspection**:
A read-only Operation that exposes a Bau Project's structure, state, or planned work.
_Avoid_: Validation, build operation

**Validation**:
An Operation that checks a Bau Project or its state without intentionally changing it.
_Avoid_: Introspection, execution

**Execution**:
An Operation that performs work and may produce Bau Outputs.
_Avoid_: Validation, mutation

**Mutation**:
An Operation whose primary purpose is to edit, remove, or refresh project state, installed or local state, or external service state.
_Avoid_: Execution, validation

**Dependency Requirement**:
A Bau Project's declared request for an external Nim package or source.
_Avoid_: Dependency, installed dependency

**Dependency Material**:
The local package content available for Bau to inspect or build against.
_Avoid_: Installed dependency, resolved dependency

**Dependency Lock**:
The recorded resolved dependency state used to reproduce dependency selection.
_Avoid_: Dependency config, installed dependency

**Dependency Source**:
The place a Dependency Requirement is fetched from or located without changing its intended package identity.
_Avoid_: Patch, override

**Dependency Patch**:
A deliberate replacement of dependency content for development, testing, or override purposes.
_Avoid_: Source, mirror

**Governance Policy**:
The dependency acceptance rules a Bau Project or Workspace applies during verification.
_Avoid_: Security config, dependency config

**Version Catalog**:
A named set of dependency version requirements that Dependency Requirements can reference.
_Avoid_: Dependency source, lock, registry

**Target**:
The artifact a Bau Project can produce or run.
_Avoid_: Task, package, binary

**Profile**:
A named compilation policy for building a Target.
_Avoid_: Mode, environment

**Feature**:
A named optional capability that can activate related capabilities or Dependency Requirements.
_Avoid_: Profile, flag, mode

**Task**:
A named workflow step in a Bau Project.
_Avoid_: Target, command

**Test Plan**:
The selected runner, test files, profiles, filters, and execution options for testing a Bau Project.
_Avoid_: Task, target

**Target Fingerprint**:
The recorded freshness identity for a Target build.
_Avoid_: Build cache, task cache

**Task Cache Entry**:
A reusable stored result for a Task invocation that runs a project command and restores declared outputs. The invocation identity includes execution shape, declared inputs, declared outputs, root Task arguments, and relevant environment inputs, but not cache location or cache read/write policy.
_Avoid_: Fingerprint, build cache

**Build Script**:
A project-scoped pre-compilation workflow that may generate files or emit build directives that affect Target compilation.
_Avoid_: Lifecycle hook, task

**Build Directive**:
A valid Bau-recognized line emitted by a Build Script that instructs Bau to adjust compilation, track file and environment inputs, register generated files, or report warnings and errors. Directive names and meanings are part of Bau's build-script contract.
_Avoid_: Hook, task output

**Lifecycle Hook**:
A legacy timing hook around actual build or install execution. Lifecycle Hooks are not the build-input protocol and do not define target freshness.
_Avoid_: Build script, task

**Toolchain Requirement**:
The external tool versions a Bau Project expects.
_Avoid_: Build environment, detected toolchain, package dependency

**Build Environment**:
The resolved execution context Bau prepares for Operations.
_Avoid_: Toolchain requirement, profile, service configuration

**Nimble Conversion**:
The translation of deterministic Nimble package metadata and literal automation into a Project Manifest.
_Avoid_: Import, migration

**Target Discovery**:
The identification of buildable Nim entrypoints that are not declared as Targets.
_Avoid_: Conversion, scanning

## Relationships

- A **Bau Project** has zero or one **Package**
- A **Bau Project** has exactly one **Project Manifest**
- A **Project Manifest** produces **Resolved State**
- A **Project Manifest** declares zero or more **Dependency Requirements**
- A **Dependency Requirement** may produce **Dependency Material**
- A **Dependency Lock** records one or more resolved **Dependency Requirements**
- A **Dependency Lock** is part of **Resolved State**
- A **Dependency Requirement** may use one **Dependency Source**
- A **Dependency Patch** replaces the content used for one **Dependency Requirement**
- A **Bau Project** may declare one **Governance Policy**
- A **Workspace** may declare one **Governance Policy**
- A **Bau Project** may declare zero or more **Version Catalogs**
- A **Workspace** may declare zero or more **Version Catalogs**
- A **Dependency Requirement** may reference one **Version Catalog**
- A **Project Manifest** declares zero or more **Targets**
- A **Target** is built under exactly one **Profile** at a time
- A **Feature** may activate zero or more other **Features**
- A **Feature** may activate zero or more **Dependency Requirements**
- A **Task** may depend on zero or more other **Tasks**
- A **Task** may delegate to an **Operation**
- A **Test Plan** belongs to one **Bau Project**
- A **Test Plan** may include one or more **Profiles**
- A **Target** may have one **Target Fingerprint** per build identity
- A **Task** may have zero or more **Task Cache Entries**
- A **Task Cache Entry** restores **Bau Outputs**
- A **Task** that delegates to an **Operation** does not produce **Task Cache Entries**
- A **Build Script** belongs to a **Bau Project**
- A **Build Script** may affect **Target** compilation
- A **Build Script** may emit zero or more **Build Directives**
- A **Build Directive** may affect **Target** compilation
- A **Build Script** may register generated files through **Build Directives**
- A **Lifecycle Hook** belongs to a **Bau Project**
- A **Bau Project** may declare **Toolchain Requirements**
- An **Operation** runs in one **Build Environment**
- A **Build Environment** includes one selected **Profile**
- A **Build Environment** includes zero or more enabled **Features**
- **Nimble Conversion** produces a **Project Manifest**
- **Target Discovery** identifies missing **Targets**
- A **Bau Project** produces zero or more **Bau Outputs**
- A **Command Surface** invokes one or more **Operations**
- An **Operation** may be invoked by multiple **Command Surfaces**
- **Introspection** is an **Operation**
- **Validation** is an **Operation**
- **Execution** is an **Operation**
- **Mutation** is an **Operation**
- A **Workspace** selects one or more **Workspace Members**
- A **Workspace Member** is a **Bau Project**
- A **Package** belongs to exactly one **Bau Project**
- A **Package** has **Package Contents**
- A **Publication** submits one **Package** with its **Package Contents**

## Example dialogue

> **Dev:** "When I add a dependency, am I changing the **Package**?"
> **Domain expert:** "No - you are changing the **Bau Project**; the **Package** is only the publishable identity and metadata."
>
> **Dev:** "If the **Project Manifest** changes but the **Resolved State** still reflects the old dependency graph, which one is wrong?"
> **Domain expert:** "Neither - the **Resolved State** is stale and needs to be refreshed from the current **Project Manifest**."
>
> **Dev:** "Is the dependency installed once it appears in the **Project Manifest**?"
> **Domain expert:** "No - at that point only the **Dependency Requirement** exists; **Dependency Material** appears after it has been made available locally."
>
> **Dev:** "When I build the CLI with sqlite support in release mode, which concepts am I combining?"
> **Domain expert:** "You are building a **Target** with a **Feature** under a **Profile**; a **Task** may wrap that workflow, but it is not the target, feature, or profile."
>
> **Dev:** "Does `[test].profiles` declare multiple **Tasks**?"
> **Domain expert:** "No - it contributes to the **Test Plan** used by a test **Operation**."
>
> **Dev:** "Are **Target Fingerprints** and **Task Cache Entries** the same cache?"
> **Domain expert:** "No - a **Target Fingerprint** decides whether compilation is fresh, while a **Task Cache Entry** can restore declared outputs for a **Task**."
>
> **Dev:** "Is skipping a Task because outputs are newer than inputs a **Task Cache Entry**?"
> **Domain expert:** "No - that is a local freshness shortcut, not a stored restorable result."
>
> **Dev:** "Is an internal mirror of a public package a **Dependency Patch**?"
> **Domain expert:** "No - if it preserves the package identity and content, it is a **Dependency Source**; a **Dependency Patch** changes the content Bau uses."
>
> **Dev:** "Should a version generator that emits compiler directives be a **Lifecycle Hook**?"
> **Domain expert:** "No - build-influencing generation belongs in a **Build Script**; **Lifecycle Hooks** exist for legacy timing compatibility."

> **Dev:** "Should a hook force a cached target to rebuild?"
> **Domain expert:** "No - **Lifecycle Hooks** are timing hooks around actual execution, not **Target Fingerprint** inputs."
>
> **Dev:** "Is `bau::generated-file=...` just task output?"
> **Domain expert:** "No - it is a **Build Directive** emitted by a **Build Script**."
>
> **Dev:** "Is a Task that runs tests still ordinary execution?"
> **Domain expert:** "No - a **Task** that delegates to a validation **Operation** inherits that operation category."
>
> **Dev:** "Can a Task that delegates to `build` or `test` use a **Task Cache Entry**?"
> **Domain expert:** "No - delegated **Operations** use their own freshness or validation behavior."
>
> **Dev:** "Can `deps = [\"build\"]` mean the built-in build **Operation**?"
> **Domain expert:** "No - task dependencies name other **Tasks**; wrap the build **Operation** in a **Task** with `command = \"build\"`."
>
> **Dev:** "Do `bau task site -- --draft` arguments flow into every dependency?"
> **Domain expert:** "No - task arguments belong to the invoked root **Task** only."
>
> **Dev:** "Should task arguments be spliced into every command string?"
> **Domain expert:** "No - prefer the task argument environment interface; command substitution is only a forwarding convenience."
>
> **Dev:** "Can `bau task bench -- cpu` and `bau task bench -- gpu` share a **Task Cache Entry**?"
> **Domain expert:** "No - root task arguments are part of the **Task Cache Entry** identity."
>
> **Dev:** "Does `bau task site --force` create a different **Task Cache Entry** identity?"
> **Domain expert:** "No - `--force` bypasses restoration and local freshness for this run, but does not change the **Task** invocation identity."
>
> **Dev:** "Does turning remote cache writes on change the **Task Cache Entry** identity?"
> **Domain expert:** "No - cache read/write settings control cache use, not what the **Task** produces."
>
> **Dev:** "Does changing `[cache].remote` create a different **Task Cache Entry** identity?"
> **Domain expert:** "No - cache locations decide where Bau reads or writes entries, not what the **Task** produces."
>
> **Dev:** "What belongs in a **Task Cache Entry** identity?"
> **Domain expert:** "The Task invocation's execution shape and declared inputs, not cache transport policy."
>
> **Dev:** "Is `bau::generated-file=relative/path.nim` relative to the script's `cwd`?"
> **Domain expert:** "No - Build Directive paths are relative to the **Bau Project** root."
>
> **Dev:** "Does listing **Package Contents** publish the **Package**?"
> **Domain expert:** "No - it inspects **Package Contents**; **Publication** is the separate act of submitting them."
>
> **Dev:** "Is `publish --dry-run` a **Publication**?"
> **Domain expert:** "No - it validates a possible **Publication**; real publishing mutates external registry state."
>
> **Dev:** "Is `bau package` the same as **Publication**?"
> **Domain expert:** "No - package generation writes a Bau Output for **Package Contents**; **Publication** submits to a registry-compatible channel."
>
> **Dev:** "Is `bau bump --patch` a release?"
> **Domain expert:** "No - it mutates Package version intent in the **Project Manifest**; release and **Publication** are separate."
>
> **Dev:** "Is the Nim version constraint the same as the environment Bau runs with?"
> **Domain expert:** "No - the constraint is a **Toolchain Requirement**; the detected tools, selected **Profile**, enabled **Features**, and execution variables form the **Build Environment**."
>
> **Dev:** "Is `bau check` **Introspection** because it prints compiler errors?"
> **Domain expert:** "No - **Introspection** is read-only structure, state, or planned-work reporting; `bau check` is validation."
>
> **Dev:** "Are `bau metadata`, `bau deps verify`, `bau build`, and `bau add` the same kind of **Operation**?"
> **Domain expert:** "No - they are **Introspection**, **Validation**, **Execution**, and **Mutation**, respectively."
>
> **Dev:** "Is generating compile commands **Introspection** because the file describes the project?"
> **Domain expert:** "No - the current operation writes a project file, so it is **Mutation**; a future read-only planning form would be separate."
>
> **Dev:** "Is every affected command **Introspection**?"
> **Domain expert:** "No - affected listing is **Introspection**, affected check and test are **Validation**, and affected build is **Execution**."
>
> **Dev:** "Is `bau test` **Execution** because it runs test code?"
> **Domain expert:** "No - the Bau operation is **Validation** because it checks the project against a **Test Plan**."
>
> **Dev:** "Is formatting **Validation** because it is usually part of CI?"
> **Domain expert:** "No - formatting is **Mutation** because it rewrites source files; linting is the validation form."
>
> **Dev:** "Is dependency sync **Validation** because CI runs it?"
> **Domain expert:** "No - dependency sync is **Mutation** because it materializes dependencies and may update **Resolved State**; dependency verification is **Validation**."
>
> **Dev:** "If a task writes a remote cache entry, does that make the task a **Mutation**?"
> **Domain expert:** "No - classify by primary purpose; the task is **Execution** with a remote-service side effect."
>
> **Dev:** "Is restoring from a remote task cache a separate **Operation**?"
> **Domain expert:** "No - it is part of **Task Cache Entry** restoration; writing a remote entry is the secondary remote-service side effect."
>
> **Dev:** "Do `blocked`, `trusted`, and release-age settings declare dependencies?"
> **Domain expert:** "No - they form a **Governance Policy** that decides whether resolved dependency state is acceptable."
>
> **Dev:** "Does `catalog:stable` fetch or lock a dependency?"
> **Domain expert:** "No - a **Version Catalog** supplies a reusable version requirement; fetching and locking happen through **Dependency Material** and **Dependency Lock**."
>
> **Dev:** "Does converting a Nimble file discover every possible executable?"
> **Domain expert:** "No - **Nimble Conversion** translates deterministic package metadata, while **Target Discovery** scans source for undeclared entrypoints."
>
> **Dev:** "Is `--watch` a separate **Operation**?"
> **Domain expert:** "No - watch mode repeats the selected **Operation** and inherits its category."
>
> **Dev:** "Is an external `bau-*` command a Bau **Operation**?"
> **Domain expert:** "Only if Bau models it as one; otherwise it is command-surface delegation with delegated behavior."

## Flagged ambiguities

- "package" was used to mean both **Bau Project** and **Package** - resolved: use **Bau Project** for the operated-on codebase and **Package** only for publishable Nim package identity.
- "package" was also used for selected files and publishing - resolved: use **Package Contents** for the selected file set and **Publication** for registry submission.
- "package generation" was confused with publishing - resolved: `bau package` writes a Bau Output for **Package Contents**; **Publication** is a separate registry mutation.
- "version bump" was confused with release - resolved: `bau bump` changes Package version intent in the **Project Manifest** and is not **Publication**.
- "config" was used for `bau.toml` even when describing project intent - resolved: use **Project Manifest** in product and architecture language, and reserve configuration/config for implementation-facing details.
- "workspace" was defined as a Bau Project even though its root primarily coordinates member projects - resolved: use **Workspace** for the coordination root and **Workspace Member** for each included **Bau Project**.
- "command" was used for both user invocation and behavior - resolved: use **Command Surface** for invocation paths and **Operation** for Bau behavior.
- "introspection" was used broadly for any command with output - resolved: use **Introspection** only for read-only Operations that expose structure, state, or planned work.
- "operation" was used without side-effect boundaries - resolved: classify Operations as **Introspection**, **Validation**, **Execution**, or **Mutation**.
- "installed dependency" was used to mean declared, local, and resolved dependency state - resolved: use **Dependency Requirement**, **Dependency Material**, and **Dependency Lock**.
- "source" and "patch" were both used for dependency replacement - resolved: use **Dependency Source** for location/mirror choices and **Dependency Patch** for content substitution.
- "governance" was treated as a generic config table - resolved: use **Governance Policy** for dependency acceptance rules.
- "catalog" was confused with dependency sources or locks - resolved: use **Version Catalog** for reusable dependency version requirements.
- "mode" was used vaguely for build shape, compiler policy, and optional capability selection - resolved: use **Target**, **Profile**, and **Feature**.
- "task" was used for configured test execution - resolved: use **Test Plan** for selected test runners, files, profiles, filters, and options.
- "task" was also used as a side-effect category - resolved: **Task** is a workflow concept; a Task that delegates to a built-in **Operation** inherits that Operation's category.
- "task dependency" was used for both Task names and built-in Operation names - resolved: Task dependencies name **Tasks** only; delegation to built-in **Operations** is explicit through a Task `command`.
- "task arguments" could mean input to the full task graph - resolved: arguments after `bau task <name> --` belong only to the invoked root **Task**.
- "task argument access" could mean environment input or command-string substitution - resolved: prefer the task argument environment interface; keep command substitution for simple forwarding.
- "task cache identity" could ignore forwarded root task arguments - resolved: root task arguments are part of the **Task Cache Entry** identity.
- "task cache identity" could mean every task-cache setting - resolved: execution shape and declared inputs are identity; cache transport policy is not.
- "force" could mean a different task identity - resolved: `--force` bypasses restoration and local freshness for the run, but does not change **Task Cache Entry** identity.
- "cache configuration" was treated as part of task output identity - resolved: cache locations and read/write policy control cache use and are excluded from **Task Cache Entry** identity.
- "build cache" was used for both target freshness and task output reuse - resolved: use **Target Fingerprint** for compilation freshness and **Task Cache Entry** for restorable task outputs.
- "task cached" could mean either restored output or local freshness - resolved: **Task Cache Entries** are stored restorable results; mtime-based output freshness is a local skip.
- "task cache" was used for both shell workflow output restoration and delegated operations - resolved: **Task Cache Entries** restore outputs only for Tasks that run project commands; delegated **Operations** use their own behavior.
- "remote task cache" could mean a separate operation category - resolved: remote reads are part of **Task Cache Entry** restoration; remote writes are a secondary external-service side effect.
- "hook" and "build script" were both used for pre/post build automation - resolved: use **Build Script** for directive-emitting pre-compilation workflows and **Lifecycle Hook** for legacy timing hooks.
- "directive" was described as generic script output - resolved: use **Build Directive** for valid Bau-recognized lines emitted by Build Scripts; unknown names, malformed lines, and missing required values are invalid.
- "outputs" was used for both task cache outputs and build-script generated files - resolved: use task `outputs` for **Task Cache Entries** and `bau::generated-file` for Build Script generated files.
- "envInputs" was used for both task cache inputs and build-script freshness - resolved: use task `envInputs` for **Task Cache Entries** and `bau::rerun-if-env-changed` for Build Script environment freshness.
- "relative path" in Build Directives could mean script working directory or project root - resolved: Build Directive paths are relative to the **Bau Project** root.
- "compiler flag directive" could mean every build-script adjustment should be a raw flag - resolved: prefer narrow Build Directives such as `bau::define` and `bau::link-lib`; keep `bau::nim-flag` as an escape hatch.
- "toolchain" was used for both required tool versions and detected execution context - resolved: use **Toolchain Requirement** for expectations and **Build Environment** for the resolved context used by Operations.
- "migration" was used for both converting Nimble metadata and finding missing targets - resolved: use **Nimble Conversion** for metadata translation and **Target Discovery** for source-derived target suggestions.
- "watch mode" could be treated as a separate operation - resolved: `--watch` repeats the selected **Operation** and inherits its category.
- "external command delegation" could be treated as core Bau operations - resolved: external `bau-*` command delegation is a **Command Surface** extension unless explicitly modeled as a Bau **Operation**.
