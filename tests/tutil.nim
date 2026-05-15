import std/[os, strutils]
import bau/util

block find_project_root_basic:
  let root = findProjectRoot(getCurrentDir() / "tests")
  doAssert root == getCurrentDir()

block find_config_basic:
  let config = findConfig(getCurrentDir() / "tests")
  doAssert config == getCurrentDir() / "bau.toml"

block hash_str_deterministic:
  let h1 = hashStr("hello")
  let h2 = hashStr("hello")
  doAssert h1 == h2

block hash_str_uses_sha256:
  doAssert hashStr("") ==
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  doAssert hashStr("hello") ==
    "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  let multiBlock = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  doAssert hashStr(multiBlock) ==
    "sha256:248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

block hash_str_different:
  let h1 = hashStr("hello")
  let h2 = hashStr("world")
  doAssert h1 != h2

block platform_triple:
  let triple = platformTriple()
  doAssert '-' in triple or '_' in triple
  doAssert triple.len > 0

block nim_version:
  let v = NimVersion
  doAssert v.len > 0
  doAssert '.' in v

block bau_version:
  doAssert BauVersion == "0.4.2"

block global_config_path:
  let p = globalConfigPath()
  doAssert "bau" in p

block run_cmd_basic:
  let (exitCode, output) = runCmd("echo", ["hello"])
  doAssert exitCode == 0
  doAssert "hello" in output
