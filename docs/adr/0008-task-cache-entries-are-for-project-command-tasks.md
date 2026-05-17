# Keep task cache entries for project-command tasks

Tasks can either run a project command through `cmd` or delegate to a built-in
Operation through `command`. We decided that Task Cache Entries restore declared
outputs only for tasks that run project commands. Root task arguments are part
of the Task Cache Entry identity. Execution shape and declared inputs are
identity: selected Profile, enabled Features, platform, Nim version, task
environment, declared environment inputs, declared input content, declared output
paths, working directory, shell, command string, and root Task arguments can all
affect what the task produces. Cache read/write settings are excluded from that
identity because they control cache use, not what the task produces. Cache
locations are excluded for the same reason: they decide where Bau reads or
writes entries, not what the task invocation produces. Tasks that delegate to
built-in Operations use the delegated Operation's own freshness, validation, or
mutation behavior.

Mtime-based task freshness is a local skip when declared outputs are newer than
declared inputs. It is not a Task Cache Entry because it does not restore a
stored result.

`--force` bypasses Task Cache Entry restoration and mtime-based local freshness
for the current run. It does not change the Task Cache Entry identity, and the
rerun may still publish cached outputs when cache writes are enabled.

This keeps target freshness, test validation, and task output restoration as
separate mechanisms. It prevents a wrapper task from making a build or test
operation appear fresh because a task output cache was restored. The trade-off is
that delegated task commands cannot use task output restoration directly; users
who need cached generated outputs should express that work as a `cmd` task with
declared inputs and outputs. Tasks that accept caller arguments get separate
cache identities for different root-task argument lists, regardless of whether
local or remote cache locations and reads/writes are enabled for that
invocation.
