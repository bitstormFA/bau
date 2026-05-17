# Make CI validation-only

Bau's `ci` command is trusted by automation, so its architecture is validation-only: it should fail when non-mutating validation gates fail, but it should not rewrite project files. Formatting remains a mutation operation; until Bau has a check-only formatting operation, CI omits formatting instead of invoking the mutating formatter directly.
