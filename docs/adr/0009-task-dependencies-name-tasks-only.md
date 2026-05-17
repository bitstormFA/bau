# Keep task dependencies inside the task graph

Tasks can delegate to built-in Operations with `command`, but task dependencies
form a graph of named Tasks. We decided that entries in `deps` resolve only to
other Tasks, not to built-in Operation names.

This keeps the task graph explicit and avoids ambiguity when a project defines a
task named `build` or wants a workflow dependency on the build Operation.
Workflows that need a built-in Operation as a prerequisite should declare a
small wrapper Task such as `command = "build"` and depend on that Task. The
trade-off is a little more manifest ceremony in exchange for a task graph whose
edges are all the same kind of object.
