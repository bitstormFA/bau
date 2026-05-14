## Discovers missing target declarations and appends them to bau.toml.

import std/[algorithm, json, os, strutils]
import bau/[config, nimscan, util]

type
  TailorResult* = object ## Target declarations inferred from source scanning.
    missingTargets*: seq[TargetInfo] ## Main modules that are not declared as targets.

proc targetExists(cfg: BauConfig; mainFile: string): bool =
  if cfg.build.main == mainFile:
    return true
  for target in cfg.targets:
    if target.main == mainFile:
      return true

proc targetNameExists(cfg: BauConfig; name: string): bool =
  if defaultTargetName(cfg) == name or cfg.build.output == name or
      cfg.package.name == name:
    return true
  for target in cfg.targets:
    if target.name == name or target.output == name:
      return true

proc discoverTargets*(cfg: BauConfig; projectDir: string): TailorResult =
  ## Scan project modules and report missing binary target declarations.
  let sourceDir = if cfg.build.source.len > 0: cfg.build.source else: "src"
  let absSource = projectDir / sourceDir
  if not dirExists(absSource):
    return

  for info in scanProjectModules(projectDir, cfg):
    if info.path.startsWith(sourceDir & "/") and info.isMainModule:
      if not targetExists(cfg, info.path):
        let base = splitFile(info.path).name
        if not targetNameExists(cfg, base):
          result.missingTargets.add(TargetInfo(
            name: base,
            kind: bkBin,
            main: info.path,
            profile: "dev"))
  result.missingTargets.sort(proc(a, b: TargetInfo): int = cmp(a.name, b.name))

proc tailorReport*(tailored: TailorResult): string =
  ## Format a human-readable report for discovered target declarations.
  if tailored.missingTargets.len == 0:
    return "tailor: no missing targets"
  result = "tailor: missing target declarations\n"
  for target in tailored.missingTargets:
    result.add("  " & target.name & " -> " & target.main & "\n")

proc appendTailoredTargets*(projectDir: string; tailored: TailorResult) =
  ## Append missing target declarations to the project's `bau.toml`.
  if tailored.missingTargets.len == 0:
    return
  let configPath = projectDir / ConfigFileName
  var content = readFileChecked(configPath)
  if not content.endsWith("\n"):
    content.add("\n")
  content.add("\n# Added by bau tailor --write\n")
  for target in tailored.missingTargets:
    content.add("[[targets]]\n")
    content.add("name = " & toTomlString(target.name) & "\n")
    content.add("kind = \"bin\"\n")
    content.add("main = " & toTomlString(target.main) & "\n")
    content.add("profile = " & toTomlString(target.profile) & "\n\n")
  saveFile(configPath, content)

proc tailorJson*(tailored: TailorResult): JsonNode =
  ## Convert tailor results to machine-readable JSON.
  var targets = newJArray()
  for target in tailored.missingTargets:
    targets.add(%*{
      "name": target.name,
      "kind": $target.kind,
      "main": target.main,
      "profile": target.profile
    })
  result = %*{
    "missingTargets": targets,
    "ok": tailored.missingTargets.len == 0
  }
