import std/[json, os, strutils]
import bau/[command, ops]

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc cleanTemp(path: string) =
  if dirExists(path):
    removeDir(path)

proc setupProject(name: string): string =
  result = getTempDir() / name
  cleanTemp(result)
  createDir(result)
  write(result / "bau.toml", """
[package]
name = "demo"
version = "0.1.0"

[build]
kind = "bin"
source = "src"
main = "src/demo.nim"
output = "demo"
""")
  write(result / "src" / "demo.nim", "echo \"demo\"\n")

block agent_setup_writes_project_local_mcp_and_skills:
  let tmp = setupProject("bau-test-agent-setup")
  defer:
    cleanTemp(tmp)

  let op = agentSetupOperation(tmp, OperationOptions(
    agentTargets: @["codex", "claude", "copilot"]))
  doAssert op.ok
  doAssert op.json["changed"].getInt() == 6

  let codex = readFile(tmp / ".codex" / "config.toml")
  doAssert codex.contains("[mcp_servers.bau]")
  doAssert codex.contains("command = \"bau\"")
  doAssert codex.contains("args = [\"mcp\"]")
  doAssert codex.contains("tool_timeout_sec = 1800")
  doAssert fileExists(tmp / ".agents" / "skills" / "bau" / "SKILL.md")
  doAssert readFile(tmp / ".agents" / "skills" / "bau" / "SKILL.md").
    contains("client-side MCP tool timeouts")

  let claude = parseJson(readFile(tmp / ".mcp.json"))
  doAssert claude["mcpServers"]["bau"]["command"].getStr() == "bau"
  doAssert claude["mcpServers"]["bau"]["args"][0].getStr() == "mcp"
  doAssert fileExists(tmp / ".claude" / "skills" / "bau" / "SKILL.md")

  let copilot = parseJson(readFile(tmp / ".vscode" / "mcp.json"))
  doAssert copilot["servers"]["bau"]["type"].getStr() == "stdio"
  doAssert copilot["servers"]["bau"]["command"].getStr() == "bau"
  doAssert fileExists(tmp / ".github" / "skills" / "bau" / "SKILL.md")

  let rerun = agentSetupOperation(tmp, OperationOptions(
    agentTargets: @["codex", "claude", "copilot"]))
  doAssert rerun.ok
  doAssert rerun.json["changed"].getInt() == 0

block agent_setup_preserves_existing_entries_without_force:
  let tmp = setupProject("bau-test-agent-setup-preserve")
  defer:
    cleanTemp(tmp)

  write(tmp / ".mcp.json", """
{
  "mcpServers": {
    "bau": {
      "command": "custom-bau",
      "args": ["mcp"]
    }
  }
}
""")
  write(tmp / ".claude" / "skills" / "bau" / "SKILL.md", "custom skill\n")

  let skipped = agentSetupOperation(tmp, OperationOptions(
    agentTargets: @["claude"]))
  doAssert skipped.ok
  doAssert skipped.json["skipped"].getInt() == 2
  doAssert readFile(tmp / ".claude" / "skills" / "bau" / "SKILL.md") ==
    "custom skill\n"

  let forced = agentSetupOperation(tmp, OperationOptions(
    agentTargets: @["claude"], force: true))
  doAssert forced.ok
  doAssert forced.json["changed"].getInt() == 2
  let claude = parseJson(readFile(tmp / ".mcp.json"))
  doAssert claude["mcpServers"]["bau"]["command"].getStr() == "bau"
  doAssert readFile(tmp / ".claude" / "skills" / "bau" / "SKILL.md").
    contains("Use Bau as the orchestration layer")

block agent_setup_dry_run_does_not_write:
  let tmp = setupProject("bau-test-agent-setup-dry-run")
  defer:
    cleanTemp(tmp)

  let planned = agentSetupOperation(tmp, OperationOptions(
    agentTargets: @["codex"], dryRun: true))
  doAssert planned.ok
  doAssert planned.json["changed"].getInt() == 2
  doAssert not fileExists(tmp / ".codex" / "config.toml")
  doAssert not fileExists(tmp / ".agents" / "skills" / "bau" / "SKILL.md")

block mcp_setup_cli_flags_parse:
  let opts = parseCliOptions(@["mcp", "setup", "--codex", "--dry-run"])
  doAssert opts.command == cmdMcp
  doAssert opts.args == @["setup"]
  doAssert opts.agentTargets == @["codex"]
  doAssert opts.dryRun

  let help = parseCliOptions(@["mcp", "--help"])
  doAssert help.command == cmdMcp
  doAssert help.help
