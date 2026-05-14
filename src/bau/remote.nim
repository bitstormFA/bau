## Provides HTTP and file helpers for remote task cache entries.

import std/[httpclient, os, strutils]
import bau/util

const RemoteCacheDir* = ".bau/cache" ## Project-relative directory used for remote task cache entries.

proc fetchRemoteTask*(url: string): string =
  ## Fetch and locally cache the content of a remote task URL.
  let cacheDir = getConfigDir() / "bau" / "cache"
  createDir(cacheDir)
  let cachedFile = cacheDir / url.replace("://", "_").replace("/", "_")
  if fileExists(cachedFile):
    try:
      result = readFile(cachedFile)
      return
    except:
      discard

  var client = newHttpClient()
  try:
    result = client.getContent(url)
    saveFile(cachedFile, result)
    success("cached remote task: " & url)
  finally:
    client.close()
