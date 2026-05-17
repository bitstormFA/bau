# Keep lifecycle hooks outside target freshness

Lifecycle Hooks are retained for compatibility with timing-based build and
install hooks. We decided that they do not contribute to Target Fingerprints and
do not run when a target build is skipped as cached.

Build Scripts are the build-input protocol: they can declare rerun inputs,
generated files, compiler flags, warnings, and errors through Build Directives.
Keeping Lifecycle Hooks outside freshness prevents legacy hook timing from
becoming a second cache invalidation system. The trade-off is that projects with
build-influencing hooks must move that work to Build Scripts to get correct
freshness behavior.
