import std/[os, strutils]
import bau/ci_templates

block github_ci_template_has_valid_run_steps:
  let tmp = getTempDir() / "bau-test-ci-template-github"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  generateCiTemplate("github", tmp)
  let content = readFile(tmp / ".github" / "workflows" / "ci.yml")
  doAssert "run: nimble install -y" in content
  doAssert "run: bau ci" in content

block gitlab_ci_template_has_valid_script_steps:
  let tmp = getTempDir() / "bau-test-ci-template-gitlab"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  generateCiTemplate("gitlab", tmp)
  let content = readFile(tmp / ".gitlab-ci.yml")
  doAssert "- nimble install -y" in content
  doAssert "- bau ci" in content
