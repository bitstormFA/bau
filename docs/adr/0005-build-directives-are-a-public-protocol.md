# Treat build directives as a public protocol

Build Scripts communicate build-relevant information to Bau by emitting Build
Directives. We decided that supported directive names and meanings are part of
Bau's public build-script contract, not private parser details.

This makes build scripts portable across Bau versions and makes misspelled
directive names, malformed directives, and missing required values fail loudly
instead of producing subtly wrong builds. Directive paths are also interpreted
relative to the Bau Project root so they match manifest paths and target
planning, independent of the script process working directory. The cost is that
changing existing directive names, meanings, path resolution, or validation
rules now requires deprecation or an explicit compatibility break; new directive
names can still be added without breaking existing scripts.
