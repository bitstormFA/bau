## Wraps Atlas dependency operations used by Bau.

import std/[os, strutils, sequtils, tables, options]
import bau/[util, config, features]

proc atlasDir*(projectDir: string): string =
  ## Return the Atlas metadata directory for a project.
  projectDir / "atlas"

proc atlasDepsDir*(projectDir: string): string =
  ## Return the dependency materialization directory used by Atlas.
  projectDir / "deps"

proc runAtlas*(args: openArray[string]; projectDir: string;
    verbose: bool = false): tuple[exitCode: int; output: string] =
  ## Run Atlas with Bau's project and dependency directory arguments.
  let atlasCmd = detectAtlas()
  var fullArgs: seq[string] = @["--project=" & projectDir, "--deps=" &
      atlasDepsDir(projectDir)]
  fullArgs.add toSeq(args)
  if verbose:
    info("atlas " & fullArgs.join(" "))
  result = runCmd(atlasCmd, fullArgs)

proc runAtlasChecked*(args: openArray[string]; projectDir: string;
    verbose: bool = false): string =
  ## Run Atlas and raise `IOError` when it exits with a nonzero status.
  let (exitCode, output) = runAtlas(args, projectDir, verbose)
  if exitCode != 0:
    raise newException(IOError, "atlas failed with exit code " & $exitCode &
        ":\n" & output)
  result = output

proc atlasInitialized*(projectDir: string): bool =
  ## Return true when Atlas metadata exists for the project.
  dirExists(atlasDir(projectDir)) and
  fileExists(atlasDir(projectDir) / "atlas.config")

proc initAtlas*(projectDir: string; verbose: bool = false) =
  ## Initialize Atlas metadata for the project when needed.
  if not atlasInitialized(projectDir):
    let (exitCode, output) = runAtlas(["init"], projectDir, verbose)
    if exitCode != 0:
      raise newException(IOError, "atlas init failed:\n" & output)
    success("initialized Atlas project")

proc syncDeps*(cfg: BauConfig; projectDir: string; verbose: bool = false;
    featureSelection: FeatureSelection = FeatureSelection()) =
  ## Materialize enabled dependencies declared in `cfg` through Atlas.
  if len(cfg.deps) == 0:
    info("no dependencies to sync")
    return

  initAtlas(projectDir, verbose)

  for name, dep in cfg.deps.pairs:
    if dependencyEnabled(cfg, name, dep, featureSelection):
      if isSome(dep.url):
        info("installing " & name & " from " & get(dep.url))
        var url = get(dep.url)
        if isSome(dep.rev):
          url = url & "#" & get(dep.rev)
        elif isSome(dep.tag):
          url = url & "#" & get(dep.tag)
        elif isSome(dep.branch):
          url = url & "#" & get(dep.branch)
        discard runAtlasChecked(["use", url], projectDir, verbose)
      elif isSome(dep.path):
        info("linking " & name & " from " & get(dep.path))
        discard runAtlasChecked(["link", get(dep.path)], projectDir, verbose)
      elif isSome(dep.version):
        info("installing " & name & " (version " & get(dep.version) & ")")
        discard runAtlasChecked(["use", name], projectDir, verbose)
      else:
        info("installing " & name)
        discard runAtlasChecked(["use", name], projectDir, verbose)

  success("deps synced")

proc updateDeps*(projectDir: string; filter: string = "";
    verbose: bool = false) =
  ## Ask Atlas to update dependencies, optionally limiting to one filter.
  initAtlas(projectDir, verbose)
  var args = @["update"]
  if filter.len > 0:
    args.add(filter)
  discard runAtlasChecked(args, projectDir, verbose)
  success("deps updated")

proc installDeps*(projectDir: string; verbose: bool = false) =
  ## Install dependencies for a Bau project, falling back to Atlas install.
  if not fileExists(projectDir / ConfigFileName):
    warn("no bau.toml found, trying atlas install")
    discard runAtlasChecked(["install"], projectDir, verbose)
    return
  let cfg = parseBauConfigFile(projectDir / ConfigFileName)
  syncDeps(cfg, projectDir, verbose)
