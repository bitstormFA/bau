## Computes and stores build fingerprints for incremental compilation.

import std/[algorithm, options, os, json, strutils]
import bau/util

type
  FingerprintInputs* = object ## Inputs that determine a target build fingerprint.
    sourcePaths*: seq[string] ## Source files and dependency files to hash.
    compilerFlags*: seq[string] ## Compiler flags included in the cache key.
    profile*: string ## Build profile name.
    configInputs*: seq[string] ## Config files included in the cache key.
    envInputs*: seq[string] ## Environment entries included in the cache key.
    platform*: string ## Platform identifier, usually `os-cpu`.
    toolchain*: string ## Toolchain identifier, usually `nim-<version>`.

  Fingerprint* = object ## Hash record used to decide whether a target is fresh.
    sourceHash*: string ## Content hash of source inputs.
    configHash*: string ## Content hash of config inputs.
    envHash*: string ## Hash of selected environment inputs.
    compilerHash*: string ## Hash of compiler and platform identity.
    flagsHash*: string ## Hash of compiler flags.
    profile*: string ## Build profile name.
    platform*: string ## Platform identifier.
    toolchain*: string ## Toolchain identifier.
    mtimeHash*: string ## Hash of source modification times.

proc initFingerprintInputs*(sourcePaths: openArray[string];
                            compilerFlags: openArray[string];
                            profile: string;
                            configInputs: openArray[string] = [];
                            envInputs: openArray[string] = []): FingerprintInputs =
  ## Build fingerprint input metadata from explicit source, flag, and config inputs.
  result.sourcePaths = @sourcePaths
  result.compilerFlags = @compilerFlags
  result.profile = profile
  result.configInputs = @configInputs
  result.envInputs = @envInputs
  result.platform = platformTriple()
  result.toolchain = "nim-" & NimVersion

proc cleanPath(path: string): string =
  normalizedPath(path).replace("\\", "/")

proc computeFingerprint*(inputs: FingerprintInputs): Fingerprint =
  ## Compute a fingerprint by hashing source, config, env, compiler, and flags.
  result.platform = if inputs.platform.len >
      0: inputs.platform else: platformTriple()
  result.profile = inputs.profile
  result.toolchain = if inputs.toolchain.len > 0: inputs.toolchain
                     else: "nim-" & NimVersion

  var sourceContent = ""
  var mtimeContent = ""
  var sourcePaths = inputs.sourcePaths
  sourcePaths.sort()
  for path in sourcePaths:
    let clean = cleanPath(path)
    sourceContent.add(clean & "\n")
    if fileExists(path):
      sourceContent.add(readFileChecked(path))
      mtimeContent.add(clean & ":" & $getLastModificationTime(path) & "\n")
    else:
      sourceContent.add("<missing>\n")
  result.sourceHash = hashStr(sourceContent)
  result.mtimeHash = hashStr(mtimeContent)

  var configContent = ""
  var configInputs = inputs.configInputs
  configInputs.sort()
  for item in configInputs:
    configContent.add(cleanPath(item) & "\n")
    if fileExists(item):
      configContent.add(readFileChecked(item))
  result.configHash = hashStr(configContent)

  var envContent = ""
  var envInputs = inputs.envInputs
  envInputs.sort()
  for item in envInputs:
    envContent.add(item & "\n")
  result.envHash = hashStr(envContent)

  var flagsStr = ""
  for f in inputs.compilerFlags:
    flagsStr.add(f & " ")
  result.flagsHash = hashStr(flagsStr)

  result.compilerHash = hashStr(result.toolchain & " " & result.platform)

proc computeFingerprint*(sourcePaths: openArray[string];
                         compilerFlags: openArray[string];
                         profile: string;
                         configInputs: openArray[string] = [];
                         envInputs: openArray[string] = []): Fingerprint =
  ## Compute a fingerprint from raw input sequences.
  computeFingerprint(initFingerprintInputs(sourcePaths, compilerFlags, profile,
    configInputs, envInputs))

proc `==`*(a, b: Fingerprint): bool =
  ## Compare all fingerprint fields for freshness checks.
  a.sourceHash == b.sourceHash and
  a.configHash == b.configHash and
  a.envHash == b.envHash and
  a.compilerHash == b.compilerHash and
  a.flagsHash == b.flagsHash and
  a.profile == b.profile and
  a.platform == b.platform and
  a.toolchain == b.toolchain and
  a.mtimeHash == b.mtimeHash

proc toJson*(fp: Fingerprint): string =
  ## Serialize a fingerprint to JSON text.
  let node = %*{
    "sourceHash": fp.sourceHash,
    "configHash": fp.configHash,
    "envHash": fp.envHash,
    "compilerHash": fp.compilerHash,
    "flagsHash": fp.flagsHash,
    "profile": fp.profile,
    "platform": fp.platform,
    "toolchain": fp.toolchain,
    "mtimeHash": fp.mtimeHash
  }
  $node

proc fromJson*(data: string): Fingerprint =
  ## Parse fingerprint JSON text.
  ##
  ## Missing fields become empty strings for compatibility with older files.
  let node = parseJson(data)
  result.sourceHash = node["sourceHash"].getStr("")
  result.configHash = node{"configHash"}.getStr("")
  result.envHash = node{"envHash"}.getStr("")
  result.compilerHash = node["compilerHash"].getStr("")
  result.flagsHash = node["flagsHash"].getStr("")
  result.profile = node["profile"].getStr("")
  result.platform = node["platform"].getStr("")
  result.toolchain = node["toolchain"].getStr("")
  result.mtimeHash = node{"mtimeHash"}.getStr("")

proc saveFingerprint*(fpDir: string; targetName: string; unitName: string;
    fp: Fingerprint) =
  ## Persist a fingerprint for a target build unit.
  let path = fpDir / targetName / unitName & ".fp"
  createDir(parentDir(path))
  saveFile(path, toJson(fp))

proc loadFingerprint*(fpDir: string; targetName: string;
    unitName: string): Option[Fingerprint] =
  ## Load a saved fingerprint, returning `none` when absent or unreadable.
  let path = fpDir / targetName / unitName & ".fp"
  if not fileExists(path):
    return none(Fingerprint)
  try:
    result = some(fromJson(readFileChecked(path)))
  except:
    result = none(Fingerprint)

proc removeFingerprint*(fpDir: string; targetName: string; unitName: string) =
  ## Remove a saved fingerprint if it exists.
  let path = fpDir / targetName / unitName & ".fp"
  if fileExists(path):
    removeFile(path)

proc cleanFingerprints*(fpDir: string) =
  ## Remove and recreate the fingerprint directory.
  if dirExists(fpDir):
    removeDir(fpDir)
    createDir(fpDir)
