## Generates CI workflow templates for Bau projects.

import std/[os]
import bau/util

const
  GithubActionsTemplate = """name: CI

on: [push, pull_request]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jiro4989/setup-nim-action@v1
        with:
          nim-version: 'stable'
      - name: Install dependencies
        run: nimble install -y
      - name: Build, lint, test
        run: bau ci
"""

  GitlabCiTemplate = """image: nimlang/nim:latest

stages:
  - test

ci:
  stage: test
  script:
    - nimble install -y
    - bau ci
"""

proc generateCiTemplate*(kind: string; projectDir: string) =
  ## Write a CI configuration template for `github` or `gitlab`.
  case kind
  of "github":
    saveFile(projectDir / ".github" / "workflows" / "ci.yml", GithubActionsTemplate)
    success("generated .github/workflows/ci.yml")
  of "gitlab":
    saveFile(projectDir / ".gitlab-ci.yml", GitlabCiTemplate)
    success("generated .gitlab-ci.yml")
  else:
    error("unknown CI kind: " & kind & " (use 'github' or 'gitlab')")
    quit(1)
