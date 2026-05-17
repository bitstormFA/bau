import std/[json, os, sequtils, streams, strutils]
import bau/mcp

proc write(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc toolNames(response: JsonNode): seq[string] =
  for tool in response["result"]["tools"].getElems():
    result.add(tool["name"].getStr())

proc callTool(projectDir, name: string; arguments: JsonNode): JsonNode =
  let request = %*{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": name,
      "arguments": arguments
    }
  }
  let response = parseJson(handleRequest($request, projectDir))
  doAssert not response.hasKey("error")
  parseJson(response["result"]["content"][0]["text"].getStr())

proc callToolEnvelope(projectDir, name: string; arguments: JsonNode): JsonNode =
  let request = %*{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": name,
      "arguments": arguments
    }
  }
  let response = parseJson(handleRequest($request, projectDir))
  doAssert not response.hasKey("error")
  response["result"]

block mcp_tools_call_real_bau_surfaces:
  let tmp = getTempDir() / "bau-test-mcp-real-tools"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "src" / "mcpdemo.nim", "echo \"mcp\"\n")
  write(tmp / "input.txt", "input\n")
  write(tmp / "bau.toml", """
[package]
name = "mcpdemo"
version = "0.1.0"

[build]
kind = "bin"
source = "src"
main = "src/mcpdemo.nim"
output = "mcpdemo"

[dependencies]
local = { path = "vendor/local" }

[[tasks]]
name = "docs"
cmd = "echo docs"
inputs = ["input.txt"]
outputs = ["docs.txt"]
""")
  write(tmp / "vendor" / "local" / "local.nim", "discard\n")
  write(tmp / "mcpdemo.nimble", """
version = "0.1.0"
author = "MCP"
description = "MCP demo"
license = "MIT"
bin = @["mcpdemo"]
""")

  let listed = parseJson(handleRequest($(%*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list",
    "params": {}
  }), tmp))
  let names = toolNames(listed)
  doAssert "bau_metadata" in names
  doAssert "bau_graph" in names
  doAssert "bau_query" in names
  doAssert "bau_cache_explain" in names
  doAssert "bau_deps_verify" in names
  doAssert "bau_install" in names
  doAssert "bau_convert" in names
  doAssert "bau_lint" in names
  doAssert "bau_ci" in names
  doAssert "bau_task" in names
  doAssert "bau_cache" in names
  doAssert "bau_tree" in names
  doAssert "bau_outdated" in names
  doAssert "bau_tailor" in names
  doAssert "bau_package" in names
  doAssert "bau_publish" in names
  doAssert "bau_bump" in names
  doAssert "bau_ci_template" in names
  doAssert "bau_env" in names
  doAssert "bau_doctor" in names
  doAssert "bau_shell_init" in names
  doAssert "bau_new" in names

  let metadata = callTool(tmp, "bau_metadata", newJObject())
  doAssert metadata["package"]["name"].getStr() == "mcpdemo"

  let converted = callTool(tmp, "bau_convert", %*{"dryRun": true})
  doAssert converted["package"].getStr() == "mcpdemo"
  doAssert converted["content"].getStr().contains("[package]")

  let graph = callTool(tmp, "bau_graph", newJObject())
  doAssert graph["nodes"].getElems().len > 0

  let query = callTool(tmp, "bau_query", %*{"kind": "deps", "name": "mcpdemo"})
  doAssert query.getElems().anyIt(it.getStr() == "local")

  let cache = callTool(tmp, "bau_cache_explain", %*{"task": "docs"})
  doAssert cache["task"].getStr() == "docs"
  doAssert cache["keyInputs"].getElems().anyIt(it.getStr().startsWith("task:docs"))

  let taskList = callTool(tmp, "bau_task", %*{"list": true})
  doAssert taskList["tasks"].getElems().anyIt(it["name"].getStr() == "docs")

  let cacheList = callTool(tmp, "bau_cache", %*{"action": "list"})
  doAssert cacheList.hasKey("entries")

  let compileCommands = callTool(tmp, "bau_compile_commands", %*{
    "profile": "dev",
    "features": []
  })
  doAssert compileCommands["entries"].getInt() >= 1
  doAssert fileExists(tmp / "compile_commands.json")

  let check = callTool(tmp, "bau_check", %*{"profile": "dev"})
  doAssert check["ok"].getBool()

  let lint = callTool(tmp, "bau_lint", newJObject())
  doAssert lint["ok"].getBool()

  let ci = callTool(tmp, "bau_ci", newJObject())
  doAssert ci["ok"].getBool()

  let install = callTool(tmp, "bau_install", %*{
    "dryRun": true,
    "installDir": "bin"
  })
  doAssert install["status"].getStr() == "planned"
  doAssert install["targets"][0]["destination"].getStr().endsWith("bin/mcpdemo")

  let explain = callTool(tmp, "bau_explain", %*{"profile": "dev"})
  doAssert explain.hasKey("cached")

  let tree = callTool(tmp, "bau_tree", newJObject())
  doAssert tree.hasKey("dependencies")

  let outdated = callTool(tmp, "bau_outdated", newJObject())
  doAssert outdated.hasKey("dependencies")

  let tailored = callTool(tmp, "bau_tailor", newJObject())
  doAssert tailored["ok"].getBool()

  let packaged = callTool(tmp, "bau_package", %*{"dryRun": true})
  doAssert packaged["ok"].getBool()
  doAssert packaged["files"].getElems().len > 0

  let publish = callTool(tmp, "bau_publish", %*{"dryRun": true})
  doAssert publish["dryRun"].getBool()
  doAssert publish["nimble"].getStr().contains("version")

  let bumped = callTool(tmp, "bau_bump", %*{"kind": "patch", "dryRun": true})
  doAssert bumped["oldVersion"].getStr() == "0.1.0"
  doAssert bumped["newVersion"].getStr() == "0.1.1"

  let env = callTool(tmp, "bau_env", newJObject())
  doAssert env["projectDir"].getStr() == tmp

  let doctor = callTool(tmp, "bau_doctor", newJObject())
  doAssert doctor["ok"].getBool()

  let ciTemplate = callTool(tmp, "bau_ci_template", %*{"kind": "github"})
  doAssert fileExists(ciTemplate["path"].getStr())

  let newProject = callTool(tmp, "bau_new", %*{
    "path": tmp / "created",
    "kind": "lib"
  })
  doAssert newProject["status"].getStr() == "initialized"
  doAssert fileExists(tmp / "created" / "bau.toml")

  let verify = callTool(tmp, "bau_deps_verify", newJObject())
  doAssert not verify["ok"].getBool()

  let removed = callTool(tmp, "bau_remove", %*{"name": "local"})
  doAssert removed["status"].getStr() == "removed"

  let cleaned = callTool(tmp, "bau_clean", newJObject())
  doAssert cleaned["status"].getStr() == "cleaned"

block mcp_framing_preserves_jsonrpc_ids:
  let request = $ %*{
    "jsonrpc": "2.0",
    "id": "init-1",
    "method": "initialize",
    "params": {}
  }
  let framed = "Content-Length: " & $request.len & "\r\n\r\n" & request
  var input = newStringStream(framed)
  let message = readMcpMessage(input)
  doAssert message == request

  let responseText = handleRequest(message, getCurrentDir())
  let response = parseJson(responseText)
  doAssert response["id"].getStr() == "init-1"

  let output = formatMcpResponse(responseText)
  doAssert output.startsWith("Content-Length: " & $responseText.len & "\r\n\r\n")

block mcp_notifications_are_silent:
  let response = handleRequest($(%*{
    "jsonrpc": "2.0",
    "method": "notifications/cancelled",
    "params": {"requestId": 2}
  }), getCurrentDir())
  doAssert response.len == 0

block mcp_tool_errors_are_marked_without_protocol_failure:
  let tmp = getTempDir() / "bau-test-mcp-tool-errors"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")
  write(tmp / "bau.toml", """
[package]
name = "demo"
version = "0.1.0"

[build]
kind = "bin"
source = "src"
main = "src/demo.nim"
output = "demo"
""")

  let result = callToolEnvelope(tmp, "bau_cache_explain", %*{"task": "missing"})
  doAssert result["isError"].getBool()
  let payload = parseJson(result["content"][0]["text"].getStr())
  doAssert payload["error"].getStr().contains("task not found")

  let noArgs = parseJson(handleRequest($(%*{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {"name": "bau_metadata"}
  }), tmp))
  doAssert not noArgs.hasKey("error")
  let metadata = parseJson(noArgs["result"]["content"][0]["text"].getStr())
  doAssert metadata["package"]["name"].getStr() == "demo"

block mcp_resources_read_effective_config:
  let tmp = getTempDir() / "bau-test-mcp-resources"
  if dirExists(tmp):
    removeDir(tmp)
  defer:
    if dirExists(tmp):
      removeDir(tmp)

  write(tmp / "src" / "demo.nim", "echo \"demo\"\n")
  write(tmp / "bau.toml", """
[package]
name = "demo"
version = "0.1.0"

[build]
kind = "bin"
source = "src"
main = "src/demo.nim"
output = "demo"

[dependencies]
local = { path = "vendor/local", optional = true }

[[tasks]]
name = "docs"
cmd = "echo docs"
inputs = ["src/demo.nim"]
outputs = ["docs"]
""")

  let response = parseJson(handleRequest($(%*{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "resources/read",
    "params": {"uri": "bau://deps"}
  }), tmp))
  doAssert not response.hasKey("error")
  let text = response["result"]["contents"][0]["text"].getStr()
  let deps = parseJson(text)
  doAssert deps["dependencies"].hasKey("local")
  doAssert deps["dependencies"]["local"]["path"].getStr() == "vendor/local"
  doAssert deps["dependencies"]["local"]["optional"].getBool()

  let manifestResponse = parseJson(handleRequest($(%*{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "resources/read",
    "params": {"uri": "bau://manifest"}
  }), tmp))
  doAssert not manifestResponse.hasKey("error")
  let manifest = parseJson(manifestResponse["result"]["contents"][0]["text"].getStr())
  doAssert manifest["package"]["name"].getStr() == "demo"
