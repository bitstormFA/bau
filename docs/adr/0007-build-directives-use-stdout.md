# Read build directives from stdout

Build Scripts need a stable way to send machine-readable Build Directives to Bau
while still letting scripts print human diagnostics. We decided that Build
Directives are recognized only from Build Script stdout. Stderr is reserved for
human diagnostics and error output.

This keeps the protocol simple for scripts that already print directive lines
and prevents diagnostic messages on stderr from accidentally changing build
planning. The trade-off is that Bau must capture stdout and stderr separately;
the current implementation captures combined output and may parse diagnostics as
directives, which is implementation drift from this contract.
