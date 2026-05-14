import std/os

proc exec(cmd: string) =
  echo "Running: " & cmd
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd, 1

proc main() =
  let testDir = currentSourcePath().parentDir()
  let outDir = getTempDir() / "bau-test-bins"
  if dirExists(outDir):
    removeDir(outDir)
  createDir(outDir)
  defer:
    if dirExists(outDir):
      removeDir(outDir)

  for f in walkFiles(testDir / "t*.nim"):
    let name = f.extractFilename
    if name == "tester.nim" or name == "thelper.nim":
      continue
    let outPath = outDir / name.changeFileExt("")
    exec "nim c -r --hints:off --out:" & quoteShell(outPath) & " " &
      quoteShell(f)

  echo "All test files completed."

main()
