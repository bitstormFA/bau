## Parses shell-style command strings for task and build-script execution.

import std/strutils

proc parseCommandLine*(cmd: string): seq[string] =
  ## Split a simple command string into argv, honoring shell-like quotes and
  ## backslash escapes. This intentionally does not expand variables or globs.
  var token = ""
  var quote = '\0'
  var escaped = false

  for ch in cmd:
    if escaped:
      token.add(ch)
      escaped = false
    elif ch == '\\':
      escaped = true
    elif quote != '\0':
      if ch == quote:
        quote = '\0'
      else:
        token.add(ch)
    elif ch == '"' or ch == '\'':
      quote = ch
    elif ch.isSpaceAscii:
      if token.len > 0:
        result.add(token)
        token = ""
    else:
      token.add(ch)

  if escaped:
    token.add('\\')
  if quote != '\0':
    raise newException(ValueError, "unterminated quoted string in command: " &
      cmd)
  if token.len > 0:
    result.add(token)
