## Resolves feature selections and optional dependency enablement.

import std/[algorithm, sets, strutils, tables]
import bau/config

type
  FeatureSelection* = object  ## Result of resolving requested and default features.
    requested*: seq[string]   ## Feature names explicitly requested by the caller.
    enabled*: seq[string]     ## Non-default feature names enabled after expansion.
    enabledDeps*: seq[string] ## Optional dependency names enabled by features.

proc normalizeFeatureDefine*(name: string): string =
  ## Convert a feature name into a Nim `-d:` compatible define suffix.
  result = ""
  for ch in name:
    if ch.isAlphaNumeric:
      result.add(ch.toLowerAscii())
    else:
      result.add('_')

proc parseFeatureList*(value: string): seq[string] =
  ## Split a comma-separated feature option into normalized feature names.
  for item in value.split(","):
    let name = item.strip()
    if name.len > 0:
      result.add(name)

proc featureExists*(cfg: BauConfig; name: string): bool =
  ## Return true when `name` is declared in the project's feature table.
  cfg.features.hasKey(name)

proc collectFeatureDeps(cfg: BauConfig; featureName: string;
    selected: var HashSet[string]; depNames: var HashSet[string]) =
  if selected.contains(featureName):
    return
  if not cfg.features.hasKey(featureName):
    if cfg.deps.hasKey(featureName):
      depNames.incl(featureName)
      return
    raise newException(ValueError, "unknown feature: " & featureName)

  selected.incl(featureName)
  for item in cfg.features[featureName].enables:
    if item.startsWith("dep:"):
      let depName = item["dep:".len..^1]
      if depName.len > 0:
        depNames.incl(depName)
    elif cfg.features.hasKey(item):
      collectFeatureDeps(cfg, item, selected, depNames)
    elif cfg.deps.hasKey(item):
      depNames.incl(item)
    else:
      raise newException(ValueError, "feature '" & featureName &
        "' references unknown item: " & item)

proc resolveFeatures*(cfg: BauConfig; requested: openArray[string];
    allFeatures = false; noDefaultFeatures = false): FeatureSelection =
  ## Resolve requested, default, and transitive feature enablement.
  ##
  ## Raises `ValueError` when a requested feature or referenced feature item is
  ## unknown.
  var seeds: seq[string]
  if allFeatures:
    for name in cfg.features.keys:
      if name != "default":
        seeds.add(name)
  else:
    if not noDefaultFeatures and cfg.features.hasKey("default"):
      seeds.add("default")
    for name in requested:
      if name.len > 0:
        seeds.add(name)

  var selected = initHashSet[string]()
  var depNames = initHashSet[string]()
  for name in seeds:
    collectFeatureDeps(cfg, name, selected, depNames)

  for name in requested:
    if name.len > 0:
      result.requested.add(name)
  for name in selected:
    if name != "default":
      result.enabled.add(name)
  for name in depNames:
    result.enabledDeps.add(name)
  result.enabled.sort()
  result.enabledDeps.sort()

proc dependencyEnabled*(cfg: BauConfig; depName: string; dep: DepInfo;
    features: FeatureSelection): bool =
  ## Return whether a dependency is active under a feature selection.
  not dep.optional or depName in features.enabledDeps

proc compilerFeatureFlags*(selection: FeatureSelection): seq[string] =
  ## Build Nim compiler `-d:` flags for enabled features.
  for name in selection.enabled:
    result.add("-d:bauFeature_" & normalizeFeatureDefine(name))
    result.add("-d:" & normalizeFeatureDefine(name))

proc enabledFeatureEnv*(selection: FeatureSelection): Table[string, string] =
  ## Build environment variables that expose enabled features to tasks.
  for name in selection.enabled:
    result["BAU_FEATURE_" & normalizeFeatureDefine(name).toUpperAscii()] = "1"
