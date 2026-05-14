## Converts Nimble project files into Bau configuration.

import std/[algorithm, json, options, os, sequtils, strutils, tables]
import bau/[config, util]

type
  ConvertSeverity* = enum ## Severity for Nimble conversion diagnostics.
    csInfo = "info" ## Informational conversion note.
    csWarning = "warning" ## Conversion warning that may need review.

  ConvertDiagnostic* = object ## Diagnostic produced while converting Nimble data.
    severity*: ConvertSeverity ## Diagnostic severity.
    line*: int ## Source line number, or zero when not tied to a line.
    message*: string ## Human-readable diagnostic message.

  NimbleLine = object
    line: int
    indent: int
    text: string

  NimbleProject* = object ## Static facts extracted from a `.nimble` file.
    nimblePath*: string ## Absolute path to the parsed `.nimble` file.
    projectDir*: string ## Project directory containing the `.nimble` file.
    packageName*: string ## Inferred or declared package name.
    version*: string ## Package version.
    authors*: seq[string] ## Package authors.
    description*: string ## Package description.
    license*: string ## Package license.
    nimRequirement*: string ## Nim version requirement.
    srcDir*: string ## Nimble `srcDir` value.
    binDir*: string ## Nimble `binDir` value.
    backend*: string ## Compiler backend requested by Nimble metadata.
    bins*: seq[string] ## Binary names declared by `bin`.
    namedBins*: Table[string, string] ## Binary names mapped to explicit source paths.
    skipDirs*: seq[string] ## Nimble package directories to exclude.
    skipFiles*: seq[string] ## Nimble package files to exclude.
    skipExt*: seq[string] ## Nimble package extensions to exclude.
    installDirs*: seq[string] ## Nimble package directories to include.
    installFiles*: seq[string] ## Nimble package files to include.
    installExt*: seq[string] ## Nimble package extensions to include.
    deps*: Table[string, DepInfo] ## Dependencies parsed from `requires`.
    features*: Table[string, FeatureInfo] ## Features parsed from Nimble feature blocks.
    tasks*: seq[TaskInfo] ## Tasks converted from Nimble task blocks.
    scripts*: ScriptInfo ## Lifecycle hooks converted from Nimble hooks.
    diagnostics*: seq[ConvertDiagnostic] ## Conversion diagnostics.

  NimbleConvertResult* = object ## Result of converting a Nimble project.
    nimblePath*: string ## Converted `.nimble` file path.
    configPath*: string ## Target `bau.toml` path.
    cfg*: BauConfig ## Converted Bau configuration.
    content*: string ## Generated `bau.toml` content.
    diagnostics*: seq[ConvertDiagnostic] ## Diagnostics emitted during conversion.
    wrote*: bool ## True when `content` was written to disk.

proc addDiag(project: var NimbleProject; severity: ConvertSeverity; line: int;
    message: string) =
  project.diagnostics.add(ConvertDiagnostic(severity: severity, line: line,
    message: message))

proc addUniqueValue(values: var seq[string]; value: string) =
  if value.len > 0 and value notin values:
    values.add(value)

proc sortedTableKeys[V](table: Table[string, V]): seq[string] =
  for key in table.keys:
    result.add(key)
  result.sort()

proc leadingSpaces(line: string): int =
  while result < line.len and line[result] == ' ':
    inc result

proc stripLineComment(line: string): string =
  var i = 0
  var inQuote = false
  var triple = false
  var quote = '\0'
  while i < line.len:
    let ch = line[i]
    if inQuote:
      result.add(ch)
      if triple:
        if ch == quote and i + 2 < line.len and line[i + 1] == quote and
            line[i + 2] == quote:
          result.add(line[i + 1])
          result.add(line[i + 2])
          i += 2
          inQuote = false
          triple = false
      elif ch == '\\' and quote == '"' and i + 1 < line.len:
        inc i
        result.add(line[i])
      elif ch == quote:
        inQuote = false
    else:
      if ch == '#':
        break
      result.add(ch)
      if ch == '"' or ch == '\'':
        inQuote = true
        quote = ch
        if ch == '"' and i + 2 < line.len and line[i + 1] == '"' and
            line[i + 2] == '"':
          triple = true
          result.add(line[i + 1])
          result.add(line[i + 2])
          i += 2
    inc i

proc cleanedLines(data: string): seq[NimbleLine] =
  let rawLines = data.splitLines()
  var pending = ""
  var pendingLine = 0
  var pendingIndent = 0
  var inTripleString = false
  for i, raw in rawLines:
    if inTripleString:
      pending.add("\n" & raw)
      if raw.count("\"\"\"") mod 2 == 1:
        let clean = pending.strip(leading = false, trailing = true)
        result.add(NimbleLine(line: pendingLine, indent: pendingIndent,
          text: clean.strip()))
        pending = ""
        inTripleString = false
    else:
      let clean = stripLineComment(raw).strip(leading = false, trailing = true)
      if clean.strip().len > 0:
        if clean.count("\"\"\"") mod 2 == 1:
          pending = clean
          pendingLine = i + 1
          pendingIndent = clean.leadingSpaces
          inTripleString = true
        else:
          result.add(NimbleLine(line: i + 1, indent: clean.leadingSpaces,
            text: clean.strip()))
  if inTripleString:
    result.add(NimbleLine(line: pendingLine, indent: pendingIndent,
      text: pending.strip()))

proc escapedChar(ch: char): char =
  case ch
  of 'n': '\n'
  of 'r': '\r'
  of 't': '\t'
  of '\\': '\\'
  of '"': '"'
  of '\'': '\''
  else: ch

proc quotedParts(text: string): seq[string] =
  var i = 0
  while i < text.len:
    var rawString = false
    if text[i] == 'r' and i + 1 < text.len and text[i + 1] == '"':
      rawString = true
      inc i
    if text[i] == '"' or text[i] == '\'':
      let quote = text[i]
      var triple = false
      if quote == '"' and i + 2 < text.len and text[i + 1] == '"' and
          text[i + 2] == '"':
        triple = true
        i += 3
      else:
        inc i
      var value = ""
      var done = false
      while i < text.len and not done:
        if triple and i + 2 < text.len and text[i] == quote and
            text[i + 1] == quote and text[i + 2] == quote:
          done = true
          i += 3
        elif not triple and text[i] == quote:
          done = true
          inc i
        elif not triple and not rawString and quote == '"' and
            text[i] == '\\' and i + 1 < text.len:
          inc i
          value.add(escapedChar(text[i]))
          inc i
        else:
          value.add(text[i])
          inc i
      result.add(value)
    else:
      inc i

proc bracketDelta(text: string): int =
  var i = 0
  var inQuote = false
  var triple = false
  var quote = '\0'
  while i < text.len:
    let ch = text[i]
    if inQuote:
      if triple:
        if ch == quote and i + 2 < text.len and text[i + 1] == quote and
            text[i + 2] == quote:
          i += 2
          inQuote = false
          triple = false
      elif ch == '\\' and quote == '"' and i + 1 < text.len:
        inc i
      elif ch == quote:
        inQuote = false
    else:
      case ch
      of '"', '\'':
        inQuote = true
        quote = ch
        if ch == '"' and i + 2 < text.len and text[i + 1] == '"' and
            text[i + 2] == '"':
          triple = true
          i += 2
      of '[', '(', '{':
        inc result
      of ']', ')', '}':
        dec result
      else:
        discard
    inc i

proc collectStatement(lines: seq[NimbleLine]; start: int): tuple[
    item: NimbleLine; next: int] =
  var item = lines[start]
  var depth = bracketDelta(item.text)
  var next = start + 1
  while next < lines.len and lines[next].indent > lines[start].indent and
      (depth > 0 or item.text.strip().endsWith(",")):
    item.text.add(" " & lines[next].text)
    depth += bracketDelta(lines[next].text)
    inc next
  result = (item: item, next: next)

proc findTopLevelEquals(text: string): int =
  var i = 0
  var inQuote = false
  var triple = false
  var quote = '\0'
  while i < text.len:
    let ch = text[i]
    if inQuote:
      if triple:
        if ch == quote and i + 2 < text.len and text[i + 1] == quote and
            text[i + 2] == quote:
          i += 2
          inQuote = false
          triple = false
      elif ch == '\\' and quote == '"' and i + 1 < text.len:
        inc i
      elif ch == quote:
        inQuote = false
    else:
      if ch == '=':
        return i
      if ch == '"' or ch == '\'':
        inQuote = true
        quote = ch
        if ch == '"' and i + 2 < text.len and text[i + 1] == '"' and
            text[i + 2] == '"':
          triple = true
          i += 2
    inc i
  -1

proc assignmentParts(text: string): tuple[ok: bool; key: string;
    value: string] =
  let pos = findTopLevelEquals(text)
  if pos < 0:
    return
  let key = text[0..<pos].strip()
  if key.len == 0 or key.contains(" ") or key.contains("\t"):
    return
  result = (ok: true, key: key, value: text[pos + 1..^1].strip())

proc parseStringValue(project: var NimbleProject; value: string; line: int;
    field: string): string =
  let parts = quotedParts(value)
  if parts.len > 0:
    result = parts[0]
  else:
    project.addDiag(csWarning, line, "could not statically read " & field &
      "; expected a string literal")

proc parseStringList(project: var NimbleProject; value: string; line: int;
    field: string): seq[string] =
  result = quotedParts(value)
  if result.len == 0 and value.strip().len > 0 and value.strip() notin [
      "@[]", "[]"]:
    project.addDiag(csWarning, line, "could not statically read " & field &
      "; expected a string or string array literal")

proc parseStringTable(project: var NimbleProject; value: string; line: int;
    field: string): Table[string, string] =
  let parts = quotedParts(value)
  if parts.len mod 2 != 0:
    project.addDiag(csWarning, line, "could not statically read " & field &
      "; expected string key/value pairs")
    return
  var i = 0
  while i + 1 < parts.len:
    result[parts[i]] = parts[i + 1]
    i += 2

proc splitRequiresSpec(spec: string): seq[string] =
  for item in spec.split(";"):
    let clean = item.strip()
    if clean.len > 0:
      result.add(clean)

proc dependencySpecParts(spec: string): tuple[name: string;
    requirement: string] =
  let parts = spec.splitWhitespace()
  if parts.len > 0:
    result.name = parts[0]
  if parts.len > 1:
    result.requirement = parts[1..^1].join(" ")

proc addFeatureDep(project: var NimbleProject; featureName, depName: string) =
  if not project.features.hasKey(featureName):
    project.features[featureName] = FeatureInfo()
  let item = "dep:" & depName
  if item notin project.features[featureName].enables:
    project.features[featureName].enables.add(item)

proc addDependency(project: var NimbleProject; spec: string; optional: bool;
    featureName: string; line: int) =
  let dep = dependencySpecParts(spec)
  if dep.name.len == 0:
    project.addDiag(csWarning, line, "ignored empty requires item")
    return

  var info =
    if project.deps.hasKey(dep.name):
      project.deps[dep.name]
    else:
      DepInfo()
  if dep.requirement.len > 0:
    info.version = some(dep.requirement)
  if optional and not (project.deps.hasKey(dep.name) and
      not project.deps[dep.name].optional):
    info.optional = true
  elif not optional:
    info.optional = false
  project.deps[dep.name] = info
  if featureName.len > 0:
    project.addFeatureDep(featureName, dep.name)

proc parseRequires(project: var NimbleProject; text: string; line: int;
    optional = false; featureName = "") =
  let items = quotedParts(text)
  if items.len == 0:
    project.addDiag(csWarning, line,
      "could not statically read requires; expected quoted dependency specs")
    return
  for item in items:
    for spec in splitRequiresSpec(item):
      let dep = dependencySpecParts(spec)
      if dep.name == "nim":
        if dep.requirement.len > 0:
          project.nimRequirement = dep.requirement
          project.addDiag(csInfo, line, "converted Nim requirement to [toolchain].nim")
        else:
          project.addDiag(csWarning, line,
            "ignored Nim requirement without a version")
      else:
        project.addDependency(spec, optional, featureName, line)

proc parseTaskHeader(text: string): tuple[name: string; description: string] =
  var body = text
  if body.endsWith(":"):
    body = body[0..^2].strip()
  body = body["task".len..^1].strip()
  let comma = body.find(',')
  if comma >= 0:
    result.name = body[0..<comma].strip()
    let parts = quotedParts(body[comma + 1..^1])
    if parts.len > 0:
      result.description = parts[0]
  else:
    result.name = body.strip()
  if result.name.startsWith("\"") or result.name.startsWith("'"):
    let parts = quotedParts(result.name)
    if parts.len > 0:
      result.name = parts[0]

proc parseFeatureHeader(text: string): string =
  let parts = quotedParts(text)
  if parts.len > 0:
    result = parts[0]
  else:
    var body = text
    if body.endsWith(":"):
      body = body[0..^2].strip()
    body = body["feature".len..^1].strip()
    let comma = body.find(',')
    result = if comma >= 0: body[0..<comma].strip() else: body

proc parseHookHeader(text: string): tuple[timing: string; name: string] =
  var body = text
  if body.endsWith(":"):
    body = body[0..^2].strip()
  let parts = body.splitWhitespace()
  if parts.len >= 2:
    result = (timing: parts[0], name: parts[1])

proc hasExpressionTail(text: string): bool =
  let doubleQuote = text.rfind('"')
  let singleQuote = text.rfind('\'')
  let pos = max(doubleQuote, singleQuote)
  result = pos >= 0 and pos + 1 < text.len and text[pos + 1..^1].strip().len > 0

proc literalCommands(project: var NimbleProject; body: openArray[NimbleLine];
    context: string): seq[string] =
  for line in body:
    let text = line.text
    if text.startsWith("exec ") or text.startsWith("execShellCmd "):
      let parts = quotedParts(text)
      if parts.len > 0:
        result.add(parts[0])
        if hasExpressionTail(text):
          project.addDiag(csWarning, line.line, context &
            " command contains NimScript expression syntax; converted literal command, review it")
      else:
        project.addDiag(csWarning, line.line, context &
          " command is not a literal exec statement")
    elif text.startsWith("run "):
      let parts = quotedParts(text)
      if parts.len > 0:
        var target = parts[0]
        if not target.endsWith(".nim"):
          target.add(".nim")
        result.add("nim c -r " & target)
        project.addDiag(csWarning, line.line, context &
          " used nimble run; converted to a plain 'nim c -r' command, review it")
      else:
        project.addDiag(csWarning, line.line, context &
          " run statement is not literal")
    elif text.len > 0:
      project.addDiag(csWarning, line.line, context &
        " contains unsupported NimScript statement: " & text)

proc joinCommands(commands: openArray[string]): string =
  for i, command in commands:
    if i > 0:
      result.add(" && ")
    result.add(command)

proc parseTask(project: var NimbleProject; header: NimbleLine;
    body: openArray[NimbleLine]) =
  let parsed = parseTaskHeader(header.text)
  if parsed.name.len == 0:
    project.addDiag(csWarning, header.line, "ignored task without a name")
    return
  let commands = project.literalCommands(body, "task '" & parsed.name & "'")
  if commands.len == 0:
    project.addDiag(csWarning, header.line, "ignored task '" & parsed.name &
      "' because no literal command could be converted")
    return
  project.tasks.add(TaskInfo(name: parsed.name, description: parsed.description,
    cmd: joinCommands(commands)))

proc parseHook(project: var NimbleProject; header: NimbleLine;
    body: openArray[NimbleLine]) =
  let hook = parseHookHeader(header.text)
  let commands = project.literalCommands(body, hook.timing & " " & hook.name)
  if commands.len == 0:
    project.addDiag(csWarning, header.line, "ignored " & hook.timing & " " &
      hook.name & " hook because no literal command could be converted")
    return
  let cmd = joinCommands(commands)
  case hook.timing & " " & hook.name
  of "before build":
    project.scripts.preBuild = some(cmd)
  of "after build":
    project.scripts.postBuild = some(cmd)
  of "after install":
    project.scripts.postInstall = some(cmd)
  else:
    project.addDiag(csWarning, header.line, "no Bau script slot for " &
      hook.timing & " " & hook.name & "; hook was not converted")

proc parseFeature(project: var NimbleProject; header: NimbleLine;
    body: openArray[NimbleLine]) =
  let featureName = parseFeatureHeader(header.text)
  if featureName.len == 0:
    project.addDiag(csWarning, header.line, "ignored feature without a name")
    return
  if not project.features.hasKey(featureName):
    project.features[featureName] = FeatureInfo()
  var i = 0
  while i < body.len:
    let statement = collectStatement(@body, i)
    if statement.item.text.startsWith("requires"):
      project.parseRequires(statement.item.text, statement.item.line,
        optional = true, featureName = featureName)
    else:
      project.addDiag(csWarning, statement.item.line, "feature '" &
        featureName &
        "' contains unsupported NimScript statement: " & statement.item.text)
    i = statement.next

proc parseAssignment(project: var NimbleProject; item: NimbleLine) =
  let parts = assignmentParts(item.text)
  if not parts.ok:
    project.addDiag(csWarning, item.line,
      "ignored unsupported NimScript statement: " &
      item.text)
    return
  case parts.key
  of "packageName", "name":
    project.packageName = project.parseStringValue(parts.value, item.line,
      parts.key)
  of "version":
    project.version = project.parseStringValue(parts.value, item.line, "version")
  of "author":
    let author = project.parseStringValue(parts.value, item.line, "author")
    if author.len > 0:
      project.authors = @[author]
  of "authors":
    project.authors = project.parseStringList(parts.value, item.line, "authors")
  of "description":
    project.description = project.parseStringValue(parts.value, item.line,
      "description")
  of "license":
    project.license = project.parseStringValue(parts.value, item.line, "license")
  of "srcDir":
    project.srcDir = project.parseStringValue(parts.value, item.line, "srcDir")
  of "binDir":
    project.binDir = project.parseStringValue(parts.value, item.line, "binDir")
  of "backend":
    project.backend = project.parseStringValue(parts.value, item.line, "backend")
  of "bin":
    project.bins = project.parseStringList(parts.value, item.line, "bin")
  of "namedBin":
    project.namedBins = project.parseStringTable(parts.value, item.line,
      "namedBin")
  of "skipDirs":
    project.skipDirs = project.parseStringList(parts.value, item.line, "skipDirs")
  of "skipFiles":
    project.skipFiles = project.parseStringList(parts.value, item.line,
      "skipFiles")
  of "skipExt":
    project.skipExt = project.parseStringList(parts.value, item.line, "skipExt")
  of "installDirs":
    project.installDirs = project.parseStringList(parts.value, item.line,
      "installDirs")
  of "installFiles":
    project.installFiles = project.parseStringList(parts.value, item.line,
      "installFiles")
  of "installExt":
    project.installExt = project.parseStringList(parts.value, item.line,
      "installExt")
  of "foreignDeps":
    project.addDiag(csWarning, item.line,
      "foreignDeps has no Bau configuration field; review system packages manually")
  else:
    if parts.key in ["let", "var", "const"] or item.text.startsWith("let ") or
        item.text.startsWith("var ") or item.text.startsWith("const "):
      project.addDiag(csWarning, item.line,
        "skipped dynamic NimScript binding: " & item.text)
    else:
      project.addDiag(csWarning, item.line,
        "ignored unsupported nimble field '" &
        parts.key & "'")

proc collectBlock(lines: seq[NimbleLine]; start: int): tuple[
    body: seq[NimbleLine]; next: int] =
  let headerIndent = lines[start].indent
  var next = start + 1
  while next < lines.len and lines[next].indent > headerIndent:
    result.body.add(lines[next])
    inc next
  result.next = next

proc isDynamicBlockHeader(text: string): bool =
  text.endsWith(":") and (
    text.startsWith("when ") or text.startsWith("if ") or
    text.startsWith("elif ") or text == "else:" or text.startsWith("for ") or
    text.startsWith("case ") or text.startsWith("of ") or
    text == "try:" or text.startsWith("except") or text == "finally:")

proc parseNimbleProject*(path: string): NimbleProject =
  ## Parse static Nimble metadata from a `.nimble` file.
  ##
  ## Dynamic NimScript control flow is skipped with warnings.
  if not fileExists(path):
    raise newException(IOError, "nimble file not found: " & path)
  result.nimblePath = absolutePath(path)
  result.projectDir = parentDir(result.nimblePath)
  result.packageName = result.nimblePath.extractFilename().replace(".nimble", "")

  let lines = cleanedLines(readFileChecked(path))
  var i = 0
  while i < lines.len:
    let item = lines[i]
    if item.text.startsWith("task ") and item.text.endsWith(":"):
      let blk = collectBlock(lines, i)
      result.parseTask(item, blk.body)
      i = blk.next
    elif item.text.startsWith("feature ") and item.text.endsWith(":"):
      let blk = collectBlock(lines, i)
      result.parseFeature(item, blk.body)
      i = blk.next
    elif (item.text.startsWith("before ") or item.text.startsWith("after ")) and
        item.text.endsWith(":"):
      let blk = collectBlock(lines, i)
      result.parseHook(item, blk.body)
      i = blk.next
    elif isDynamicBlockHeader(item.text):
      let blk = collectBlock(lines, i)
      result.addDiag(csWarning, item.line,
        "skipped dynamic NimScript control flow; review generated config")
      i = blk.next
    else:
      let statement = collectStatement(lines, i)
      if statement.item.text.startsWith("requires"):
        result.parseRequires(statement.item.text, statement.item.line)
      elif statement.item.text.startsWith("when ") or
          statement.item.text.startsWith("if ") or
          statement.item.text.startsWith("for ") or
          statement.item.text.startsWith("case ") or
          statement.item.text.startsWith("try:"):
        result.addDiag(csWarning, statement.item.line,
          "skipped dynamic NimScript control flow; review generated config")
      elif statement.item.text.startsWith("import ") or
          statement.item.text.startsWith("include "):
        result.addDiag(csWarning, statement.item.line,
          "skipped NimScript module directive: " & statement.item.text)
      else:
        result.parseAssignment(statement.item)
      i = statement.next

proc sourceDirFor(project: var NimbleProject): string =
  if project.srcDir.len > 0:
    if dirExists(project.projectDir / project.srcDir):
      result = project.srcDir
    else:
      project.addDiag(csWarning, 0, "srcDir '" & project.srcDir &
        "' does not exist; using '.' so root-level modules are included")
      result = "."
  elif dirExists(project.projectDir / "src"):
    result = "src"
  else:
    result = "."

proc normalizeRel(path: string): string =
  path.replace("\\", "/")

proc candidateMain(project: NimbleProject; name, explicitPath: string): seq[string] =
  if explicitPath.len > 0:
    let path = if explicitPath.endsWith(".nim"): explicitPath
               else: explicitPath & ".nim"
    result.add(path.normalizeRel)
  if project.binDir.len > 0:
    result.add((project.binDir / (name & ".nim")).normalizeRel)
  if project.srcDir.len > 0:
    result.add((project.srcDir / (name & ".nim")).normalizeRel)
  result.add((name & ".nim").normalizeRel)
  if project.srcDir.len == 0:
    result.add(("src" / (name & ".nim")).normalizeRel)

proc inferMain(project: NimbleProject; name: string;
    explicitPath = ""): string =
  let candidates = candidateMain(project, name, explicitPath)
  for path in candidates:
    if fileExists(project.projectDir / path):
      return path
  if candidates.len > 0:
    result = candidates[0]

proc inferLibraryMain(project: NimbleProject): string =
  let name = project.packageName
  for path in candidateMain(project, name, ""):
    if fileExists(project.projectDir / path):
      return path
  if project.srcDir.len > 0:
    result = (project.srcDir / (name & ".nim")).normalizeRel
  else:
    result = ("src" / (name & ".nim")).normalizeRel

proc extPattern(ext: string): string =
  let clean = ext.strip().strip(chars = {'.'})
  if clean.len > 0:
    result = "*." & clean

proc applyPackageFileLists(cfg: var BauConfig; project: NimbleProject) =
  for path in project.installDirs:
    cfg.package.includeFiles.addUniqueValue(path.normalizeRel)
  for path in project.installFiles:
    cfg.package.includeFiles.addUniqueValue(path.normalizeRel)
  for ext in project.installExt:
    cfg.package.includeFiles.addUniqueValue(extPattern(ext))
  for path in project.skipDirs:
    cfg.package.excludeFiles.addUniqueValue(path.normalizeRel)
  for path in project.skipFiles:
    cfg.package.excludeFiles.addUniqueValue(path.normalizeRel)
  for ext in project.skipExt:
    cfg.package.excludeFiles.addUniqueValue(extPattern(ext))

proc toBauConfig*(project: var NimbleProject): BauConfig =
  ## Convert parsed Nimble project metadata into a Bau configuration.
  result = initBauConfig()
  result.package.name = project.packageName
  result.package.version = project.version
  result.package.authors = project.authors
  result.package.description = project.description
  result.package.license = project.license
  result.package.edition = "2026"
  result.applyPackageFileLists(project)
  result.toolchain.nim = project.nimRequirement

  result.build.source = project.sourceDirFor()
  result.build.backend = project.backend

  var convertedTargets: seq[TargetInfo]
  for name in project.bins:
    convertedTargets.add(TargetInfo(name: name, kind: bkBin,
      main: project.inferMain(name)))
  for name in sortedTableKeys(project.namedBins):
    var already = false
    for target in convertedTargets:
      if target.name == name:
        already = true
    if not already:
      convertedTargets.add(TargetInfo(name: name, kind: bkBin,
        main: project.inferMain(name, project.namedBins[name])))

  if convertedTargets.len > 0:
    result.build.kind = bkBin
    result.build.main = convertedTargets[0].main
    result.build.output = convertedTargets[0].name
    for i in 1..<convertedTargets.len:
      convertedTargets[i].profile = "dev"
      result.targets.add(convertedTargets[i])
  else:
    result.build.kind = bkLib
    result.build.main = project.inferLibraryMain()

  result.profiles["dev"] = ProfileInfo(flags: @["--debugInfo:on"], gc: "orc")
  result.profiles["release"] = ProfileInfo(flags: @["--opt:speed"], gc: "orc")
  result.deps = project.deps
  result.features = project.features
  result.tasks = project.tasks
  result.scripts = project.scripts

  var docEntrypoints: seq[string]
  let libraryMain = project.inferLibraryMain()
  if fileExists(project.projectDir / libraryMain):
    docEntrypoints.addUniqueValue(libraryMain)
  if result.build.main.len > 0:
    docEntrypoints.addUniqueValue(result.build.main)
  for target in result.targets:
    docEntrypoints.addUniqueValue(target.main)
  if docEntrypoints.len > 0:
    result.docs.configured = true
    result.docs.entrypoints = docEntrypoints

proc tomlArray(values: openArray[string]): string =
  result = "["
  for i, value in values:
    if i > 0:
      result.add(", ")
    result.add(toTomlString(value))
  result.add("]")

proc addTomlField(content: var string; name, value: string) =
  if value.len > 0:
    content.add(name & " = " & toTomlString(value) & "\n")

proc addTomlArrayField(content: var string; name: string;
    values: openArray[string]) =
  if values.len > 0:
    content.add(name & " = " & tomlArray(values) & "\n")

proc depTomlValue(dep: DepInfo): string =
  if dep.url.isNone and dep.tag.isNone and dep.branch.isNone and
      dep.rev.isNone and dep.path.isNone and dep.registry.isNone and
      not dep.optional:
    if dep.version.isSome:
      return toTomlString(dep.version.get())
    return "{}"

  var parts: seq[string]
  if dep.version.isSome:
    parts.add("version = " & toTomlString(dep.version.get()))
  if dep.url.isSome:
    parts.add("git = " & toTomlString(dep.url.get()))
  if dep.path.isSome:
    parts.add("path = " & toTomlString(dep.path.get()))
  if dep.registry.isSome:
    parts.add("registry = " & toTomlString(dep.registry.get()))
  if dep.tag.isSome:
    parts.add("tag = " & toTomlString(dep.tag.get()))
  if dep.branch.isSome:
    parts.add("branch = " & toTomlString(dep.branch.get()))
  if dep.rev.isSome:
    parts.add("rev = " & toTomlString(dep.rev.get()))
  if dep.optional:
    parts.add("optional = true")
  result = "{ " & parts.join(", ") & " }"

proc bauTomlContent*(cfg: BauConfig): string =
  ## Render a Bau configuration as TOML generated by `bau convert`.
  result = "# Generated by bau convert from a .nimble file\n\n"
  result.add("[package]\n")
  result.addTomlField("name", cfg.package.name)
  result.addTomlField("version", cfg.package.version)
  result.addTomlField("description", cfg.package.description)
  result.addTomlArrayField("authors", cfg.package.authors)
  result.addTomlField("license", cfg.package.license)
  result.addTomlField("edition", cfg.package.edition)
  result.addTomlArrayField("include", cfg.package.includeFiles)
  result.addTomlArrayField("exclude", cfg.package.excludeFiles)
  result.add("\n")

  result.add("[build]\n")
  result.add("kind = " & toTomlString($cfg.build.kind) & "\n")
  result.addTomlField("source", cfg.build.source)
  result.addTomlField("main", cfg.build.main)
  result.addTomlField("output", cfg.build.output)
  result.addTomlField("backend", cfg.build.backend)
  result.add("\n")

  if cfg.toolchain.nim.len > 0 or cfg.toolchain.atlas.len > 0:
    result.add("[toolchain]\n")
    result.addTomlField("nim", cfg.toolchain.nim)
    result.addTomlField("atlas", cfg.toolchain.atlas)
    result.add("\n")

  for name in sortedTableKeys(cfg.profiles):
    let profile = cfg.profiles[name]
    result.add("[profile." & name & "]\n")
    result.addTomlArrayField("flags", profile.flags)
    result.addTomlField("gc", profile.gc)
    result.addTomlField("backend", profile.backend)
    if profile.define.len > 0:
      var parts: seq[string]
      for key in sortedTableKeys(profile.define):
        parts.add(key & " = " & toTomlString(profile.define[key]))
      result.add("define = { " & parts.join(", ") & " }\n")
    result.add("\n")

  if cfg.deps.len > 0:
    result.add("[dependencies]\n")
    for name in sortedTableKeys(cfg.deps):
      result.add(name & " = " & depTomlValue(cfg.deps[name]) & "\n")
    result.add("\n")

  if cfg.features.len > 0:
    result.add("[features]\n")
    for name in sortedTableKeys(cfg.features):
      result.add(name & " = " & tomlArray(cfg.features[name].enables) & "\n")
    result.add("\n")

  if cfg.scripts.preBuild.isSome or cfg.scripts.postBuild.isSome or
      cfg.scripts.postInstall.isSome:
    result.add("[scripts]\n")
    if cfg.scripts.preBuild.isSome:
      result.addTomlField("preBuild", cfg.scripts.preBuild.get())
    if cfg.scripts.postBuild.isSome:
      result.addTomlField("postBuild", cfg.scripts.postBuild.get())
    if cfg.scripts.postInstall.isSome:
      result.addTomlField("postInstall", cfg.scripts.postInstall.get())
    result.add("\n")

  if cfg.docs.configured:
    result.add("[docs]\n")
    result.addTomlArrayField("entrypoints", cfg.docs.entrypoints)
    result.addTomlField("outDir", cfg.docs.outDir)
    result.add("\n")

  for target in cfg.targets:
    result.add("[[targets]]\n")
    result.addTomlField("name", target.name)
    result.add("kind = " & toTomlString($target.kind) & "\n")
    result.addTomlField("main", target.main)
    result.addTomlField("profile", target.profile)
    result.addTomlArrayField("requiredFeatures", target.requiredFeatures)
    result.addTomlArrayField("tags", target.tags)
    result.add("\n")

  for task in cfg.tasks:
    result.add("[[tasks]]\n")
    result.addTomlField("name", task.name)
    result.addTomlField("cmd", task.cmd)
    result.addTomlField("description", task.description)
    result.addTomlArrayField("deps", task.deps)
    result.addTomlArrayField("inputs", task.inputs)
    result.addTomlArrayField("outputs", task.outputs)
    if task.cwd.isSome:
      result.addTomlField("cwd", task.cwd.get())
    if task.shell.len > 0:
      result.addTomlField("shell", task.shell)
    result.addTomlArrayField("envInputs", task.envInputs)
    if task.cache:
      result.add("cache = true\n")
    result.addTomlArrayField("requiredFeatures", task.requiredFeatures)
    result.addTomlArrayField("tags", task.tags)
    if task.env.len > 0:
      var parts: seq[string]
      for key in sortedTableKeys(task.env):
        parts.add(key & " = " & toTomlString(task.env[key]))
      result.add("env = { " & parts.join(", ") & " }\n")
    result.add("\n")

proc findNimbleFile*(projectDir: string; explicitPath = ""): string =
  ## Locate the `.nimble` file to convert.
  ##
  ## Raises when no file is found or multiple candidates require disambiguation.
  if explicitPath.len > 0:
    let candidate = if explicitPath.isAbsolute: explicitPath
                    else: absolutePath(projectDir) / explicitPath
    if dirExists(candidate):
      return findNimbleFile(candidate)
    if fileExists(candidate):
      return candidate
    raise newException(IOError, "nimble file not found: " & candidate)

  let dir = absolutePath(projectDir)
  let preferred = dir / (dir.extractFilename & ".nimble")
  if fileExists(preferred):
    return preferred
  let files = toSeq(walkFiles(dir / "*.nimble"))
  if files.len == 0:
    raise newException(IOError, "no .nimble file found in " & dir)
  if files.len > 1:
    raise newException(IOError, "multiple .nimble files found in " & dir &
      "; pass the file to convert explicitly")
  files[0]

proc convertNimbleProject*(projectDir: string = getCurrentDir();
    nimblePath: string = ""; write = true; force = false): NimbleConvertResult =
  ## Convert a Nimble project to Bau configuration and optionally write it.
  var path = findNimbleFile(projectDir, nimblePath)
  path = absolutePath(path)
  var project = parseNimbleProject(path)
  let cfg = project.toBauConfig()
  let content = bauTomlContent(cfg)
  let configPath = project.projectDir / ConfigFileName
  if write and fileExists(configPath) and not force:
    raise newException(IOError, ConfigFileName & " already exists at " &
      configPath & " (use --force to overwrite)")
  if write:
    saveFile(configPath, content)
  result = NimbleConvertResult(nimblePath: path, configPath: configPath,
    cfg: cfg, content: content, diagnostics: project.diagnostics, wrote: write)

proc diagnosticJson(diag: ConvertDiagnostic): JsonNode =
  %*{
    "severity": $diag.severity,
    "line": diag.line,
    "message": diag.message
  }

proc convertResultJson*(conversion: NimbleConvertResult): JsonNode =
  ## Convert a Nimble conversion result to JSON.
  var diagnostics = newJArray()
  for diag in conversion.diagnostics:
    diagnostics.add(diagnosticJson(diag))
  %*{
    "nimblePath": conversion.nimblePath,
    "configPath": conversion.configPath,
    "wrote": conversion.wrote,
    "package": conversion.cfg.package.name,
    "targets": conversion.cfg.targets.len + 1,
    "dependencies": conversion.cfg.deps.len,
    "tasks": conversion.cfg.tasks.len,
    "diagnostics": diagnostics
  }

proc parseNimbleFile*(path: string): Option[BauConfig] =
  ## Parse a `.nimble` file into Bau config, returning `none` on failure.
  if not fileExists(path):
    return none(BauConfig)
  try:
    var project = parseNimbleProject(path)
    result = some(project.toBauConfig())
  except CatchableError:
    result = none(BauConfig)

proc findProjectConfig*(startDir: string = getCurrentDir()): BauConfig =
  ## Find a Bau config, or fall back to parsing a nearby `.nimble` file.
  try:
    let projectDir = findProjectRoot()
    result = parseBauConfigFile(projectDir / ConfigFileName)
    return
  except IOError:
    discard

  var dir = absolutePath(startDir)
  while dir.len > 0:
    let nimbleFiles = toSeq(walkFiles(dir / "*.nimble"))
    if nimbleFiles.len > 0:
      let parsed = parseNimbleFile(nimbleFiles[0])
      if isSome(parsed):
        result = get(parsed)
        return
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent

  result = initBauConfig()
