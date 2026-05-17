## Checks Nim and Atlas versions against configured constraints.

import std/strutils
import bau/[config, util]

type
  ToolchainCheck* = object ## Result of checking configured external tools.
    ok*: bool              ## True when every required tool is present and compatible.
    messages*: seq[string] ## Human-readable detections or failure messages.

proc parseVersionParts(value: string): seq[int] =
  for part in value.split("."):
    var digits = ""
    for ch in part:
      if ch.isDigit:
        digits.add(ch)
      else:
        break
    if digits.len > 0:
      result.add(parseInt(digits))

proc compareVersions(a, b: string): int =
  let aa = parseVersionParts(a)
  let bb = parseVersionParts(b)
  let n = max(aa.len, bb.len)
  for i in 0..<n:
    let av = if i < aa.len: aa[i] else: 0
    let bv = if i < bb.len: bb[i] else: 0
    if av < bv:
      return -1
    if av > bv:
      return 1
  result = 0

proc versionSatisfies*(actual, requirement: string): bool =
  ## Return whether a version satisfies a simple comparison requirement.
  ##
  ## Supported operators are `>=`, `>`, `<=`, `<`, `=`, and bare equality.
  let req = requirement.strip()
  if req.len == 0:
    return true
  if req.startsWith(">="):
    return compareVersions(actual, req[2..^1].strip()) >= 0
  if req.startsWith(">"):
    return compareVersions(actual, req[1..^1].strip()) > 0
  if req.startsWith("<="):
    return compareVersions(actual, req[2..^1].strip()) <= 0
  if req.startsWith("<"):
    return compareVersions(actual, req[1..^1].strip()) < 0
  if req.startsWith("="):
    return compareVersions(actual, req[1..^1].strip()) == 0
  result = compareVersions(actual, req) == 0

proc detectedNimVersion*(): string =
  ## Return the version reported by `nim --version`, or an empty string.
  let nim = detectNimCompiler()
  let (exitCode, output) = runCmd(nim, ["--version"])
  if exitCode != 0:
    return ""
  for line in output.splitLines():
    let marker = "Nim Compiler Version "
    let idx = line.find(marker)
    if idx >= 0:
      let rest = line[idx + marker.len..^1]
      return rest.splitWhitespace()[0]

proc detectedAtlasVersion*(): string =
  ## Return the version reported by `atlas --version`, or an empty string.
  let atlas = try: detectAtlas() except CatchableError: return ""
  let (exitCode, output) = runCmd(atlas, ["--version"])
  if exitCode != 0:
    return ""
  for token in output.splitWhitespace():
    if token.len > 0 and token[0].isDigit:
      return token

proc checkToolchain*(cfg: BauConfig): ToolchainCheck =
  ## Check detected tool versions against the project's toolchain policy.
  result.ok = true
  try:
    let nimPath = detectNimCompiler()
    let nimVer = detectedNimVersion()
    result.messages.add("nim: " & nimPath &
      (if nimVer.len > 0: " " & nimVer else: ""))
    if cfg.toolchain.nim.len > 0 and nimVer.len > 0 and
        not versionSatisfies(nimVer, cfg.toolchain.nim):
      result.ok = false
      result.messages.add("nim does not satisfy " & cfg.toolchain.nim)
  except CatchableError as e:
    result.ok = false
    result.messages.add(e.msg)

  if cfg.toolchain.atlas.len > 0:
    try:
      let atlasPath = detectAtlas()
      let atlasVer = detectedAtlasVersion()
      result.messages.add("atlas: " & atlasPath &
        (if atlasVer.len > 0: " " & atlasVer else: ""))
      if cfg.toolchain.atlas.len > 0 and atlasVer.len > 0 and
          not versionSatisfies(atlasVer, cfg.toolchain.atlas):
        result.ok = false
        result.messages.add("atlas does not satisfy " & cfg.toolchain.atlas)
    except CatchableError as e:
      result.ok = false
      result.messages.add(e.msg)

proc ensureToolchain*(cfg: BauConfig) =
  ## Raise `IOError` when the configured toolchain requirements are not met.
  let check = checkToolchain(cfg)
  if not check.ok:
    raise newException(IOError, check.messages.join("\n"))
