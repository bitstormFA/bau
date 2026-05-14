import std/[tables, options]
import bau/config

proc testConfig(): string =
  """[package]
name = "testproj"
version = "1.0.0"
description = "A test project"

[build]
name = "default"
kind = "bin"
source = "src"
main = "src/main.nim"
output = "testproj"
includeDefault = true

[test]
runner = "tests/all.nim"
profiles = ["dev", "release", "danger"]
defaultProfile = "dev"
fullProfiles = ["dev", "release", "danger", "asan"]
recursive = true
exclude = ["thelper.nim"]
showOutput = "always"

[profile.dev]
flags = ["--debugInfo:on"]
gc = "orc"

[profile.release]
flags = ["--opt:speed"]
gc = "orc"

[[targets]]
name = "cli"
kind = "bin"
main = "src/cli.nim"
output = "test-cli"
source = "tools"
paths = ["src", "vendor/src"]
profile = "release"

[dependencies]
nre = { git = "https://github.com/flaviut/nre.git", tag = "v2.0.0" }
regex = ">=2.0.0"

[[tasks]]
name = "docs"
command = "test"
profile = "asan"
deps = ["build"]
acceptArgs = true

[aliases]
lint = "task lint"
"""

block parse_package_info:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.package.name == "testproj"
  doAssert cfg.package.version == "1.0.0"
  doAssert cfg.package.description == "A test project"

block parse_build_info:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.build.kind == bkBin
  doAssert cfg.build.source == "src"
  doAssert cfg.build.main == "src/main.nim"
  doAssert cfg.build.output == "testproj"
  doAssert cfg.build.name == "default"
  doAssert cfg.build.includeDefault

block parse_profiles:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.profiles.hasKey("dev")
  doAssert cfg.profiles["dev"].flags == @["--debugInfo:on"]
  doAssert cfg.profiles["dev"].gc == "orc"

block parse_targets:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.targets.len == 1
  doAssert cfg.targets[0].name == "cli"
  doAssert cfg.targets[0].kind == bkBin
  doAssert cfg.targets[0].output == "test-cli"
  doAssert cfg.targets[0].source == "tools"
  doAssert cfg.targets[0].paths == @["src", "vendor/src"]

block parse_dependencies:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.deps.hasKey("nre")
  doAssert cfg.deps["nre"].url == some("https://github.com/flaviut/nre.git")
  doAssert cfg.deps["nre"].tag == some("v2.0.0")
  doAssert cfg.deps.hasKey("regex")
  doAssert cfg.deps["regex"].version == some(">=2.0.0")

block parse_dependency_locking_extensions:
  let cfg = parseBauConfig("""
[package]
name = "sources"

[dependencies]
gitpkg = { git = "https://example.com/gitpkg.git", rev = "abc123" }
regpkg = { version = ">=1.0", registry = "mirror" }

[source.mirror]
registry = "https://example.com/index"
replaceWith = "vendor"

[source.vendor]
directory = "vendor"
""")
  doAssert cfg.deps["gitpkg"].rev == some("abc123")
  doAssert cfg.deps["regpkg"].registry == some("mirror")
  doAssert cfg.sources["mirror"].registry == "https://example.com/index"
  doAssert cfg.sources["mirror"].replaceWith == "vendor"
  doAssert cfg.sources["vendor"].directory == "vendor"

block parse_tasks:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.tasks.len == 1
  doAssert cfg.tasks[0].name == "docs"
  doAssert cfg.tasks[0].command == "test"
  doAssert cfg.tasks[0].profile == "asan"
  doAssert cfg.tasks[0].deps == @["build"]
  doAssert cfg.tasks[0].acceptArgs

block parse_test_and_aliases:
  let cfg = parseBauConfig(testConfig())
  doAssert cfg.test.runner == "tests/all.nim"
  doAssert cfg.test.profiles == @["dev", "release", "danger"]
  doAssert cfg.test.defaultProfile == "dev"
  doAssert cfg.test.fullProfiles == @["dev", "release", "danger", "asan"]
  doAssert cfg.test.recursive
  doAssert cfg.test.exclude == @["thelper.nim"]
  doAssert cfg.test.showOutput == "always"
  doAssert cfg.aliases["lint"] == "task lint"

block parse_docs:
  let cfg = parseBauConfig("""
[package]
name = "docdemo"

[docs]
outDir = "site/api"
docRoot = "@path"
entrypoints = ["src/docdemo.nim"]
include = ["src/docdemo/*.nim"]
exclude = ["src/docdemo/private/**"]
flags = ["-d:docs"]
project = false
index = false
runExamples = false
includePrivate = true
sourceUrl = "https://example.com/src/$path#L$line"
""")
  doAssert cfg.docs.outDir == "site/api"
  doAssert cfg.docs.docRoot == "@path"
  doAssert cfg.docs.entrypoints == @["src/docdemo.nim"]
  doAssert cfg.docs.includeFiles == @["src/docdemo/*.nim"]
  doAssert cfg.docs.excludeFiles == @["src/docdemo/private/**"]
  doAssert cfg.docs.flags == @["-d:docs"]
  doAssert not cfg.docs.project
  doAssert not cfg.docs.index
  doAssert not cfg.docs.runExamples
  doAssert cfg.docs.includePrivate
  doAssert cfg.docs.sourceUrl == "https://example.com/src/$path#L$line"

block parse_empty_config:
  let cfg = parseBauConfig("[package]\nname = \"minimal\"")
  doAssert cfg.package.name == "minimal"
  doAssert cfg.build.kind == bkBin
  doAssert cfg.build.source == "src"
  doAssert cfg.docs.outDir == "docs"
  doAssert cfg.docs.project
  doAssert cfg.docs.index
  doAssert cfg.docs.runExamples

block resolve_profile_with_extends:
  let cfg = parseBauConfig(testConfig())
  var dev = resolveProfile(cfg.profiles, "dev")
  doAssert dev.gc == "orc"
