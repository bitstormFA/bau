## Writes project-local coding-agent setup files for Bau MCP and skills.

import std/[json, os, strutils]
import bau/util

type
  AgentTarget* = enum ## Coding-agent host to configure.
    atCodex = "codex"
    atClaude = "claude"
    atCopilot = "copilot"

  AgentSetupOptions* = object ## Options for project-local agent setup.
    targets*: seq[AgentTarget] ## Agent hosts to configure.
    force*: bool               ## Replace existing divergent generated entries.
    dryRun*: bool              ## Report planned changes without writing files.

  AgentSetupFile* = object ## One setup file that was planned or written.
    agent*: string            ## Agent host name.
    kind*: string             ## File role, such as `mcp` or `skill`.
    path*: string             ## Absolute path to the setup file.
    action*: string           ## create, update, unchanged, skipped, etc.
    changed*: bool            ## True when the action would change the file.
    reason*: string           ## Explanation for skipped or failed actions.

  AgentSetupResult* = object ## Project-local agent setup summary.
    projectDir*: string       ## Bau project directory.
    files*: seq[AgentSetupFile] ## File-level results.

const BauAgentSkillContent* = """---
name: bau
description: Use Bau for this Nim project. Use when building, testing, running, managing dependencies, working with tasks/cache/docs, inspecting metadata, or connecting coding agents through MCP.
---

# Bau

Use Bau as the orchestration layer for this Nim project.

## First Moves

1. Read `bau.toml` before changing build behavior.
2. Prefer Bau commands over raw `nim`, `nimble`, or `atlas` commands.
3. Use `bau metadata --json` when you need project structure.
4. Preserve `bau.lock`; use `bau deps sync --locked` for normal setup.
5. Use `bau deps sync` only when intentionally refreshing dependency state.

## Common Commands

```sh
bau check
bau test
bau ci
bau run -- --help
bau deps sync --locked
bau deps verify
bau doc
bau affected list --since origin/main
bau affected test --since origin/main
```

## Agent Integration

Bau exposes the same operations through CLI and MCP. Start the MCP server with:

```sh
bau mcp
```

Use MCP tools for metadata, graph, query, affected-work, dependency status, and
other short operations when they are available. Prefer the `bau` CLI for
long-running `check`, `test`, `ci`, `build`, and `run` workflows in Codex or
VS Code so progress can stream and client-side MCP tool timeouts do not interrupt
the work.
"""

proc parseAgentTarget*(value: string): AgentTarget =
  ## Parse a command-line or JSON target name.
  case value.strip().toLowerAscii()
  of "codex":
    atCodex
  of "claude", "claude-code":
    atClaude
  of "copilot", "github-copilot", "vscode", "vs-code":
    atCopilot
  else:
    raise newException(ValueError, "unknown agent target: " & value)

proc defaultAgentTargets*(): seq[AgentTarget] =
  ## Return every supported project-local agent setup target.
  @[atCodex, atClaude, atCopilot]

proc normalizeAgentTargets*(values: openArray[string]): seq[AgentTarget] =
  ## Parse and de-duplicate agent target names.
  if values.len == 0:
    return defaultAgentTargets()
  for value in values:
    let target = parseAgentTarget(value)
    if target notin result:
      result.add(target)

proc targetName(target: AgentTarget): string =
  case target
  of atCodex:
    "codex"
  of atClaude:
    "claude"
  of atCopilot:
    "copilot"

proc mcpConfigPath(projectDir: string; target: AgentTarget): string =
  case target
  of atCodex:
    projectDir / ".codex" / "config.toml"
  of atClaude:
    projectDir / ".mcp.json"
  of atCopilot:
    projectDir / ".vscode" / "mcp.json"

proc skillPath(projectDir: string; target: AgentTarget): string =
  case target
  of atCodex:
    projectDir / ".agents" / "skills" / "bau" / "SKILL.md"
  of atClaude:
    projectDir / ".claude" / "skills" / "bau" / "SKILL.md"
  of atCopilot:
    projectDir / ".github" / "skills" / "bau" / "SKILL.md"

proc mcpServerJson(): JsonNode =
  %*{"type": "stdio", "command": "bau", "args": ["mcp"]}

proc codexMcpToml(): string =
  "[mcp_servers.bau]\n" &
    "command = \"bau\"\n" &
    "args = [\"mcp\"]\n" &
    "tool_timeout_sec = 1800\n"

proc withTrailingNewline(content: string): string =
  if content.len == 0 or content[^1] == '\n':
    content
  else:
    content & "\n"

proc appendTomlBlock(content, blockContent: string): string =
  let base = content.strip(trailing = true)
  if base.len == 0:
    withTrailingNewline(blockContent)
  else:
    base & "\n\n" & withTrailingNewline(blockContent)

proc isTomlHeader(line: string): bool =
  let trimmed = line.strip()
  trimmed.startsWith("[") and trimmed.endsWith("]")

proc tomlHeaderName(line: string): string =
  let trimmed = line.strip()
  if trimmed.startsWith("[[") and trimmed.endsWith("]]"):
    trimmed[2..^3].strip()
  elif trimmed.startsWith("[") and trimmed.endsWith("]"):
    trimmed[1..^2].strip()
  else:
    ""

proc isTomlTableFamily(line, family: string): bool =
  let name = tomlHeaderName(line)
  name == family or name.startsWith(family & ".")

proc removeTomlTableFamily(content, family: string): string =
  var lines: seq[string]
  var skipping = false
  for line in content.splitLines():
    if line.isTomlHeader():
      skipping = line.isTomlTableFamily(family)
      if not skipping:
        lines.add(line)
    elif not skipping:
      lines.add(line)
  result = lines.join("\n").strip(trailing = true)
  if result.len > 0:
    result.add("\n")

proc recordFile(agent, kind, path, action: string; changed: bool;
    reason = ""): AgentSetupFile =
  AgentSetupFile(agent: agent, kind: kind, path: path, action: action,
    changed: changed, reason: reason)

proc writeExactFile(agent, kind, path, content: string;
    opts: AgentSetupOptions): AgentSetupFile =
  let exists = fileExists(path)
  let oldContent = if exists: readFile(path) else: ""
  if exists and oldContent == content:
    return recordFile(agent, kind, path, "unchanged", false)
  if exists and not opts.force:
    return recordFile(agent, kind, path, "skipped", false,
      "file already exists; use --force to replace it")

  let action =
    if opts.dryRun:
      if exists: "would-update" else: "would-create"
    else:
      if exists: "updated" else: "created"
  if not opts.dryRun:
    saveFile(path, content)
  recordFile(agent, kind, path, action, true)

proc loadJsonConfig(path: string): JsonNode =
  if not fileExists(path):
    return newJObject()
  result = parseJson(readFile(path))
  if result.kind != JObject:
    raise newException(ValueError, path & " must contain a JSON object")

proc upsertJsonMcpConfig(agent, path, topKey: string;
    opts: AgentSetupOptions): AgentSetupFile =
  let server = mcpServerJson()
  var root = loadJsonConfig(path)
  if root.hasKey(topKey) and root[topKey].kind != JObject:
    return recordFile(agent, "mcp", path, "failed", false,
      topKey & " must be a JSON object")
  if not root.hasKey(topKey):
    root[topKey] = newJObject()

  let exists = root[topKey].hasKey("bau")
  if exists and root[topKey]["bau"] == server:
    return recordFile(agent, "mcp", path, "unchanged", false)
  if exists and not opts.force:
    return recordFile(agent, "mcp", path, "skipped", false,
      "MCP server 'bau' already exists; use --force to replace it")

  root[topKey]["bau"] = server
  let content = withTrailingNewline(pretty(root))
  let action =
    if opts.dryRun:
      if exists: "would-update" else: "would-create"
    else:
      if exists: "updated" else: "created"
  if not opts.dryRun:
    saveFile(path, content)
  recordFile(agent, "mcp", path, action, true)

proc upsertCodexMcpConfig(path: string;
    opts: AgentSetupOptions): AgentSetupFile =
  let blockContent = codexMcpToml()
  let content = if fileExists(path): readFile(path) else: ""
  let existing = content.contains("[mcp_servers.bau]")
  if existing and content.contains(blockContent.strip()):
    return recordFile("codex", "mcp", path, "unchanged", false)
  if existing and not opts.force:
    return recordFile("codex", "mcp", path, "skipped", false,
      "MCP server 'bau' already exists; use --force to replace it")

  let withoutBau = removeTomlTableFamily(content, "mcp_servers.bau")
  let nextContent = appendTomlBlock(withoutBau, blockContent)
  let action =
    if opts.dryRun:
      if existing: "would-update" else: "would-create"
    else:
      if existing: "updated" else: "created"
  if not opts.dryRun:
    saveFile(path, nextContent)
  recordFile("codex", "mcp", path, action, true)

proc setupAgent(projectDir: string; target: AgentTarget;
    opts: AgentSetupOptions): seq[AgentSetupFile] =
  let agent = target.targetName()
  case target
  of atCodex:
    result.add(upsertCodexMcpConfig(projectDir.mcpConfigPath(target), opts))
  of atClaude:
    result.add(upsertJsonMcpConfig(agent, projectDir.mcpConfigPath(target),
      "mcpServers", opts))
  of atCopilot:
    result.add(upsertJsonMcpConfig(agent, projectDir.mcpConfigPath(target),
      "servers", opts))
  result.add(writeExactFile(agent, "skill", projectDir.skillPath(target),
    BauAgentSkillContent, opts))

proc setupAgents*(projectDir: string;
    opts: AgentSetupOptions): AgentSetupResult =
  ## Write MCP registration and project-local skill files for agent hosts.
  result.projectDir = projectDir
  let targets =
    if opts.targets.len == 0: defaultAgentTargets() else: opts.targets
  for target in targets:
    result.files.add(setupAgent(projectDir, target, opts))

proc fileNode(file: AgentSetupFile): JsonNode =
  %*{
    "agent": file.agent,
    "kind": file.kind,
    "path": file.path,
    "action": file.action,
    "changed": file.changed,
    "reason": file.reason
  }

proc agentSetupResultJson*(setup: AgentSetupResult): JsonNode =
  ## Convert an agent setup result to stable machine-readable JSON.
  var files = newJArray()
  var changed = 0
  var skipped = 0
  var failed = 0
  for file in setup.files:
    files.add(fileNode(file))
    if file.changed:
      inc changed
    if file.action == "skipped":
      inc skipped
    if file.action == "failed":
      inc failed
  %*{
    "projectDir": setup.projectDir,
    "ok": failed == 0,
    "changed": changed,
    "skipped": skipped,
    "failed": failed,
    "files": files
  }
