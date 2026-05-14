## Baumeister (bau) — A modern build tool for Nim.
##
## Entry point: parses CLI options, loads configuration,
## and dispatches to the appropriate command handler.

import std/os
import bau/[util, command, mcp]

proc main() =
  let rawArgs = commandLineParams()
  if rawArgs.len > 0 and (rawArgs[0] == "--mcp" or rawArgs[0] == "mcp"):
    var projectDir = getCurrentDir()
    try:
      projectDir = findProjectRoot()
    except:
      discard
    mcpServerLoop(projectDir)
    return

  let opts = parseCliOptions(rawArgs)
  case opts.command
  of cmdVersion:
    printVersion()
    return
  of cmdHelp, cmdNone:
    printHelp()
    return
  else:
    dispatchCommand(opts)

when isMainModule:
  try:
    main()
  except CatchableError as e:
    error("fatal: " & e.msg)
    quit(1)
