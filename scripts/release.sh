#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh (--major|--minor|--patch|--version X.Y.Z) [options]
  scripts/release.sh (major|minor|patch|X.Y.Z) [options]

Prepare and publish a Bau release to Nimble and GitHub.

Modes:
  --dry-run, -n       Rehearse in an isolated temporary clone. This is default.
  --execute           Perform the real release in the current checkout.

Version selection:
  --major             Bump MAJOR, reset MINOR and PATCH to 0.
  --minor             Bump MINOR, reset PATCH to 0.
  --patch             Bump PATCH.
  --version X.Y.Z     Use an explicit SemVer version.

Options:
  --remote NAME       Git remote to push to. Default: origin.
  --branch NAME       Branch to push HEAD to. Default: current branch.
  --github-draft      Create the GitHub release as a draft in execute mode.
  --nimble-tags TEXT  Tags for first-time Nimble package registration.
                     Default: nim build cli dependencies packaging
  --keep-temp         Keep the temporary dry-run clone even on success.
  --log-dir PATH      Write report and logs under PATH.
                     Default: build/release/<timestamp>-<version-or-bump>.
  --help, -h          Show this help.

Examples:
  scripts/release.sh --minor
  scripts/release.sh --version 0.5.0 --dry-run
  scripts/release.sh --version 0.5.0 --execute
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="dry-run"
BUMP_KIND=""
TARGET_VERSION=""
REMOTE="origin"
BRANCH=""
GITHUB_DRAFT="false"
NIMBLE_TAGS="nim build cli dependencies packaging"
KEEP_TEMP="false"
CUSTOM_LOG_DIR=""

START_EPOCH="$(date +%s)"
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
STATUS="success"
FAILURE_STEP=""
FAILURE_COMMAND=""
FAILURE_LOG=""
FAILURE_EXIT_CODE=""
FAILURE_MESSAGE=""

WORK_ROOT=""
TMP_ROOT=""
REPORT_DIR=""
LOG_DIR=""
STEPS_FILE=""
REPORT_FILE=""
NOTES_FILE=""
PACKAGE_NAME=""
PREVIOUS_VERSION=""
PREVIOUS_TAG=""
TARGET_TAG=""
SOURCE_COMMIT=""
RELEASE_COMMIT=""
SOURCE_DIRTY="false"
DRY_RUN_CLEANED_UP="false"
STEP_INDEX=0
REPORT_READY="false"
METADATA_BEFORE=""
METADATA_AFTER=""

info() {
  printf '[release] %s\n' "$*" >&2
}

json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "${1-}")"
}

slug() {
  local value="${1,,}"
  value="${value//[^a-z0-9]/-}"
  value="$(printf '%s' "$value" | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  if [[ -z "$value" ]]; then
    value="step"
  fi
  printf '%s' "$value"
}

format_command() {
  local out=""
  local arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [[ -n "$out" ]]; then
      out+=" "
    fi
    out+="$quoted"
  done
  printf '%s' "$out"
}

record_step() {
  local name="$1"
  local status="$2"
  local command="$3"
  local exit_code="$4"
  local duration="$5"
  local log_file="$6"

  {
    printf '{"index":%s,' "$STEP_INDEX"
    printf '"name":%s,' "$(json_string "$name")"
    printf '"status":%s,' "$(json_string "$status")"
    printf '"command":%s,' "$(json_string "$command")"
    printf '"exitCode":%s,' "$exit_code"
    printf '"durationSeconds":%s,' "$duration"
    printf '"log":%s' "$(json_string "$log_file")"
    printf '}\n'
  } >> "$STEPS_FILE"
}

run_step() {
  local name="$1"
  shift
  STEP_INDEX=$((STEP_INDEX + 1))

  local log_file="$LOG_DIR/$(printf '%03d' "$STEP_INDEX")-$(slug "$name").log"
  local command
  command="$(format_command "$@")"
  local start end duration exit_code

  info "$(printf '%02d' "$STEP_INDEX"). $name"
  start="$(date +%s)"
  (
    cd "$WORK_ROOT"
    "$@"
  ) >"$log_file" 2>&1
  exit_code=$?
  end="$(date +%s)"
  duration=$((end - start))

  if [[ "$exit_code" -eq 0 ]]; then
    record_step "$name" "success" "$command" "$exit_code" "$duration" "$log_file"
    return 0
  fi

  record_step "$name" "failed" "$command" "$exit_code" "$duration" "$log_file"
  STATUS="failed"
  FAILURE_STEP="$name"
  FAILURE_COMMAND="$command"
  FAILURE_LOG="$log_file"
  FAILURE_EXIT_CODE="$exit_code"
  FAILURE_MESSAGE="command failed"
  return "$exit_code"
}

run_function_step() {
  local name="$1"
  local command_label="$2"
  local function_name="$3"
  shift 3
  STEP_INDEX=$((STEP_INDEX + 1))

  local log_file="$LOG_DIR/$(printf '%03d' "$STEP_INDEX")-$(slug "$name").log"
  local start end duration exit_code

  info "$(printf '%02d' "$STEP_INDEX"). $name"
  start="$(date +%s)"
  (
    cd "$WORK_ROOT"
    "$function_name" "$@"
  ) >"$log_file" 2>&1
  exit_code=$?
  end="$(date +%s)"
  duration=$((end - start))

  if [[ "$exit_code" -eq 0 ]]; then
    record_step "$name" "success" "$command_label" "$exit_code" "$duration" "$log_file"
    return 0
  fi

  record_step "$name" "failed" "$command_label" "$exit_code" "$duration" "$log_file"
  STATUS="failed"
  FAILURE_STEP="$name"
  FAILURE_COMMAND="$command_label"
  FAILURE_LOG="$log_file"
  FAILURE_EXIT_CODE="$exit_code"
  FAILURE_MESSAGE="command failed"
  return "$exit_code"
}

run_capture() {
  local __var_name="$1"
  local name="$2"
  shift 2
  STEP_INDEX=$((STEP_INDEX + 1))

  local log_file="$LOG_DIR/$(printf '%03d' "$STEP_INDEX")-$(slug "$name").log"
  local stdout_file="$log_file.stdout"
  local command
  command="$(format_command "$@")"
  local start end duration exit_code output

  info "$(printf '%02d' "$STEP_INDEX"). $name"
  start="$(date +%s)"
  (
    cd "$WORK_ROOT"
    "$@"
  ) >"$stdout_file" 2>"$log_file.stderr"
  exit_code=$?
  output="$(cat "$stdout_file")"
  cat "$stdout_file" "$log_file.stderr" >"$log_file"
  rm -f "$stdout_file" "$log_file.stderr"
  end="$(date +%s)"
  duration=$((end - start))

  if [[ "$exit_code" -eq 0 ]]; then
    printf -v "$__var_name" '%s' "$output"
    record_step "$name" "success" "$command" "$exit_code" "$duration" "$log_file"
    return 0
  fi

  record_step "$name" "failed" "$command" "$exit_code" "$duration" "$log_file"
  STATUS="failed"
  FAILURE_STEP="$name"
  FAILURE_COMMAND="$command"
  FAILURE_LOG="$log_file"
  FAILURE_EXIT_CODE="$exit_code"
  FAILURE_MESSAGE="command failed"
  return "$exit_code"
}

fail() {
  STATUS="failed"
  FAILURE_MESSAGE="$1"
  if [[ -z "$FAILURE_STEP" ]]; then
    FAILURE_STEP="release script"
  fi
  return 1
}

require_clean_tree_for_execute() {
  if [[ "$MODE" == "execute" ]] && [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
    fail "real releases require a clean working tree before version/docs changes"
    return 1
  fi
}

validate_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

bump_semver() {
  local version="$1"
  local kind="$2"
  if ! validate_semver "$version"; then
    fail "package.version must use SemVer MAJOR.MINOR.PATCH: $version"
    return 1
  fi

  local major minor patch
  IFS=. read -r major minor patch <<<"$version"
  case "$kind" in
    major) printf '%s.0.0\n' "$((major + 1))" ;;
    minor) printf '%s.%s.0\n' "$major" "$((minor + 1))" ;;
    patch) printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))" ;;
    *)
      fail "version bump must be one of: major, minor, patch"
      return 1
      ;;
  esac
}

compare_semver() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  if (( left_major != right_major )); then
    (( left_major > right_major )) && printf '1\n' || printf -- '-1\n'
    return
  fi
  if (( left_minor != right_minor )); then
    (( left_minor > right_minor )) && printf '1\n' || printf -- '-1\n'
    return
  fi
  if (( left_patch != right_patch )); then
    (( left_patch > right_patch )) && printf '1\n' || printf -- '-1\n'
    return
  fi
  printf '0\n'
}

update_toml_package_version() {
  local path="$1"
  local version="$2"
  local tmp="${path}.tmp.$$"
  awk -v new_version="$version" '
    BEGIN { in_package = 0; changed = 0 }
    /^\[package\][[:space:]]*$/ { in_package = 1; print; next }
    /^\[/ && in_package { in_package = 0 }
    in_package && /^[[:space:]]*version[[:space:]]*=/ && !changed {
      sub(/=.*/, "= \"" new_version "\"")
      changed = 1
    }
    { print }
    END { if (!changed) exit 42 }
  ' "$path" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$path"
}

update_nimble_version() {
  local path="$1"
  local version="$2"
  local tmp="${path}.tmp.$$"
  awk -v new_version="$version" '
    BEGIN { changed = 0 }
    /^[[:space:]]*version[[:space:]]*=/ && !changed {
      sub(/=.*/, "= \"" new_version "\"")
      changed = 1
    }
    { print }
    END { if (!changed) exit 42 }
  ' "$path" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$path"
}

write_version_files() {
  update_toml_package_version "$WORK_ROOT/bau.toml" "$TARGET_VERSION" || {
    printf 'could not update [package].version in bau.toml\n' >&2
    return 1
  }

  local nimble_path="$WORK_ROOT/${PACKAGE_NAME}.nimble"
  if [[ -f "$nimble_path" ]]; then
    update_nimble_version "$nimble_path" "$TARGET_VERSION" || {
      printf 'could not update version in %s\n' "$nimble_path" >&2
      return 1
    }
  fi
}

generate_release_notes() {
  local notes_path="$1"
  local tag="$2"
  local previous="$3"
  local package="$4"
  local version="$5"
  local range_label log_range

  mkdir -p "$(dirname "$notes_path")"
  if [[ -n "$previous" ]]; then
    range_label="$previous..HEAD"
    log_range="$previous..HEAD"
  else
    range_label="initial history"
    log_range="HEAD"
  fi

  {
    printf '# %s\n\n' "$tag"
    printf 'Release %s %s.\n\n' "$package" "$version"
    printf '## Changes\n\n'
    if [[ -n "$previous" ]]; then
      printf 'Changes since `%s`:\n\n' "$previous"
    else
      printf 'Initial release notes:\n\n'
    fi
    git -C "$WORK_ROOT" log "$log_range" --oneline --decorate --no-merges | sed 's/^/- /'
    printf '\n## Verification\n\n'
    printf -- '- `bau deps sync`\n'
    printf -- '- `bau deps sync --locked`\n'
    printf -- '- `bau deps verify`\n'
    printf -- '- `bau doctor`\n'
    printf -- '- `bau check --all-targets`\n'
    printf -- '- `bau test`\n'
    printf -- '- `bau doc`\n'
    printf -- '- `bau package --list --dry-run`\n'
    printf -- '- `bau publish --dry-run`\n'
    printf -- '- `bau build --profile release`\n'
    printf '\nGenerated from `%s`.\n' "$range_label"
  } > "$notes_path"
}

nimble_package_registered() {
  local package="$1"
  local search_output
  search_output="$(nimble search "$package" 2>&1)" || {
    printf '%s\n' "$search_output"
    return 1
  }
  printf '%s\n' "$search_output" | awk -v package="$package" '
    $0 == package ":" { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

ensure_nimble_package_registration() {
  if nimble_package_registered "$PACKAGE_NAME"; then
    printf '%s is already registered in Nimble packages; version availability comes from Git tags.\n' "$PACKAGE_NAME"
    return 0
  fi

  local output exit_code
  output="$(printf '%s\n' "$NIMBLE_TAGS" | nimble publish 2>&1)"
  exit_code=$?
  printf '%s\n' "$output"
  if [[ "$exit_code" -ne 0 ]]; then
    return "$exit_code"
  fi
  if printf '%s\n' "$output" | grep -Eiq '(^|[[:space:]])Error:|EOF reached'; then
    return 1
  fi
  printf '%s\n' "$output" | grep -Eiq 'Success: Pull request successful|Success:.*publish|Success:.*Publish'
}

planned_commands_json() {
  local draft_flag=""
  if [[ "$GITHUB_DRAFT" == "true" ]]; then
    draft_flag=" --draft"
  fi
  local command
  local commands=(
    "git push $REMOTE HEAD:$BRANCH"
    "git push $REMOTE refs/tags/$TARGET_TAG"
    "nimble publish if $PACKAGE_NAME is not already registered"
    "gh release create $TARGET_TAG --title $TARGET_TAG --notes-file $NOTES_FILE$draft_flag"
  )

  printf '['
  local first="true"
  for command in "${commands[@]}"; do
    if [[ "$first" == "true" ]]; then
      first="false"
    else
      printf ','
    fi
    json_string "$command"
  done
  printf ']'
}

write_report() {
  if [[ "$REPORT_READY" != "true" ]]; then
    return
  fi

  local finished_at end_epoch duration
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  end_epoch="$(date +%s)"
  duration=$((end_epoch - START_EPOCH))
  RELEASE_COMMIT="$(git -C "$WORK_ROOT" rev-parse HEAD 2>/dev/null || printf '')"

  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "script": %s,\n' "$(json_string "scripts/release.sh")"
    printf '  "status": %s,\n' "$(json_string "$STATUS")"
    printf '  "mode": %s,\n' "$(json_string "$MODE")"
    printf '  "dryRun": %s,\n' "$(if [[ "$MODE" == "dry-run" ]]; then printf true; else printf false; fi)"
    printf '  "startedAt": %s,\n' "$(json_string "$STARTED_AT")"
    printf '  "finishedAt": %s,\n' "$(json_string "$finished_at")"
    printf '  "durationSeconds": %s,\n' "$duration"
    printf '  "package": %s,\n' "$(json_string "$PACKAGE_NAME")"
    printf '  "previousVersion": %s,\n' "$(json_string "$PREVIOUS_VERSION")"
    printf '  "targetVersion": %s,\n' "$(json_string "$TARGET_VERSION")"
    printf '  "previousTag": %s,\n' "$(json_string "$PREVIOUS_TAG")"
    printf '  "targetTag": %s,\n' "$(json_string "$TARGET_TAG")"
    printf '  "sourceCommit": %s,\n' "$(json_string "$SOURCE_COMMIT")"
    printf '  "releaseCommit": %s,\n' "$(json_string "$RELEASE_COMMIT")"
    printf '  "sourceDirty": %s,\n' "$SOURCE_DIRTY"
    printf '  "remote": %s,\n' "$(json_string "$REMOTE")"
    printf '  "branch": %s,\n' "$(json_string "$BRANCH")"
    printf '  "workDir": %s,\n' "$(json_string "$WORK_ROOT")"
    printf '  "reportDir": %s,\n' "$(json_string "$REPORT_DIR")"
    printf '  "logDir": %s,\n' "$(json_string "$LOG_DIR")"
    printf '  "reportFile": %s,\n' "$(json_string "$REPORT_FILE")"
    printf '  "releaseNotes": %s,\n' "$(json_string "$NOTES_FILE")"
    printf '  "dryRunTempCleanedUp": %s,\n' "$DRY_RUN_CLEANED_UP"
    printf '  "plannedExternalCommands": '
    planned_commands_json
    printf ',\n'
    printf '  "failure": '
    if [[ "$STATUS" == "failed" ]]; then
      printf '{'
      printf '"step":%s,' "$(json_string "$FAILURE_STEP")"
      printf '"message":%s,' "$(json_string "$FAILURE_MESSAGE")"
      printf '"command":%s,' "$(json_string "$FAILURE_COMMAND")"
      if [[ -n "$FAILURE_EXIT_CODE" ]]; then
        printf '"exitCode":%s,' "$FAILURE_EXIT_CODE"
      else
        printf '"exitCode":null,'
      fi
      printf '"log":%s' "$(json_string "$FAILURE_LOG")"
      printf '}'
    else
      printf 'null'
    fi
    printf ',\n'
    printf '  "steps": [\n'
    if [[ -f "$STEPS_FILE" ]]; then
      local first="true"
      while IFS= read -r step_json; do
        if [[ "$first" == "true" ]]; then
          first="false"
        else
          printf ',\n'
        fi
        printf '    %s' "$step_json"
      done < "$STEPS_FILE"
      if [[ "$first" == "false" ]]; then
        printf '\n'
      fi
    fi
    printf '  ]\n'
    printf '}\n'
  } > "$REPORT_FILE"

  cat "$REPORT_FILE"
}

cleanup() {
  local exit_code=$?
  if [[ "$REPORT_READY" == "true" ]]; then
    local cleanup_temp_after_report="false"
    if [[ "$MODE" == "dry-run" && -n "$TMP_ROOT" && -d "$TMP_ROOT" && "$KEEP_TEMP" != "true" && "$STATUS" == "success" ]]; then
      DRY_RUN_CLEANED_UP="true"
      cleanup_temp_after_report="true"
    fi
    write_report
    if [[ "$cleanup_temp_after_report" == "true" ]]; then
      rm -rf "$TMP_ROOT"
    fi
    if [[ "$STATUS" == "success" ]]; then
      info "release $MODE completed; report: $REPORT_FILE"
    else
      info "release $MODE failed; report: $REPORT_FILE"
      if [[ -n "$FAILURE_LOG" ]]; then
        info "failure log: $FAILURE_LOG"
      fi
    fi
  fi

  if [[ "$STATUS" == "failed" ]]; then
    exit 1
  fi
  exit "$exit_code"
}

parse_args() {
  local selector_count=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --major|--minor|--patch)
        BUMP_KIND="${1#--}"
        selector_count=$((selector_count + 1))
        shift
        ;;
      major|minor|patch)
        BUMP_KIND="$1"
        selector_count=$((selector_count + 1))
        shift
        ;;
      --version)
        if [[ $# -lt 2 ]]; then
          printf 'missing value for --version\n' >&2
          usage >&2
          exit 2
        fi
        TARGET_VERSION="$2"
        selector_count=$((selector_count + 1))
        shift 2
        ;;
      [0-9]*.[0-9]*.[0-9]*)
        TARGET_VERSION="$1"
        selector_count=$((selector_count + 1))
        shift
        ;;
      --dry-run|-n)
        MODE="dry-run"
        shift
        ;;
      --execute)
        MODE="execute"
        shift
        ;;
      --remote)
        if [[ $# -lt 2 ]]; then
          printf 'missing value for --remote\n' >&2
          usage >&2
          exit 2
        fi
        REMOTE="$2"
        shift 2
        ;;
      --branch)
        if [[ $# -lt 2 ]]; then
          printf 'missing value for --branch\n' >&2
          usage >&2
          exit 2
        fi
        BRANCH="$2"
        shift 2
        ;;
      --github-draft)
        GITHUB_DRAFT="true"
        shift
        ;;
      --nimble-tags)
        if [[ $# -lt 2 ]]; then
          printf 'missing value for --nimble-tags\n' >&2
          usage >&2
          exit 2
        fi
        NIMBLE_TAGS="$2"
        shift 2
        ;;
      --keep-temp)
        KEEP_TEMP="true"
        shift
        ;;
      --log-dir)
        if [[ $# -lt 2 ]]; then
          printf 'missing value for --log-dir\n' >&2
          usage >&2
          exit 2
        fi
        CUSTOM_LOG_DIR="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'unknown argument: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ "$selector_count" -ne 1 ]]; then
    printf 'select exactly one of --major, --minor, --patch, or --version X.Y.Z\n' >&2
    usage >&2
    exit 2
  fi

  if [[ -n "$TARGET_VERSION" ]] && ! validate_semver "$TARGET_VERSION"; then
    printf 'explicit version must use SemVer MAJOR.MINOR.PATCH: %s\n' "$TARGET_VERSION" >&2
    exit 2
  fi
}

prepare_workspace() {
  SOURCE_COMMIT="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
  if [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
    SOURCE_DIRTY="true"
  fi

  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git -C "$SOURCE_ROOT" rev-parse --abbrev-ref HEAD)"
    if [[ "$BRANCH" == "HEAD" ]]; then
      fail "cannot infer branch from detached HEAD; pass --branch"
      return 1
    fi
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bau-release.XXXXXX")"
    WORK_ROOT="$TMP_ROOT/repo"
    git clone --quiet --no-hardlinks "$SOURCE_ROOT" "$WORK_ROOT" || {
      fail "could not create dry-run clone"
      return 1
    }
    local remote_url
    remote_url="$(git -C "$SOURCE_ROOT" remote get-url "$REMOTE" 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
      git -C "$WORK_ROOT" remote set-url "$REMOTE" "$remote_url"
    fi
    git -C "$WORK_ROOT" checkout --quiet "$SOURCE_COMMIT" || {
      fail "could not check out source commit in dry-run clone"
      return 1
    }
    if ! git -C "$WORK_ROOT" config user.name >/dev/null; then
      git -C "$WORK_ROOT" config user.name "Bau Release Dry Run"
    fi
    if ! git -C "$WORK_ROOT" config user.email >/dev/null; then
      git -C "$WORK_ROOT" config user.email "release-dry-run@example.invalid"
    fi
  else
    WORK_ROOT="$SOURCE_ROOT"
  fi
}

prepare_report_dir() {
  local label
  if [[ -n "$TARGET_VERSION" ]]; then
    label="$TARGET_VERSION"
  else
    label="$BUMP_KIND"
  fi
  label="$(slug "$label")"

  if [[ -n "$CUSTOM_LOG_DIR" ]]; then
    REPORT_DIR="$(cd "$SOURCE_ROOT" && mkdir -p "$CUSTOM_LOG_DIR" && cd "$CUSTOM_LOG_DIR" && pwd)"
  else
    REPORT_DIR="$SOURCE_ROOT/build/release/$(date -u +"%Y%m%dT%H%M%SZ")-$label"
    mkdir -p "$REPORT_DIR"
  fi
  LOG_DIR="$REPORT_DIR/logs"
  mkdir -p "$LOG_DIR"
  STEPS_FILE="$REPORT_DIR/steps.ndjson"
  REPORT_FILE="$REPORT_DIR/report.json"
  : > "$STEPS_FILE"
  REPORT_READY="true"
}

read_initial_metadata() {
  run_capture METADATA_BEFORE "Read project metadata" bau metadata --json || return 1
  PACKAGE_NAME="$(printf '%s\n' "$METADATA_BEFORE" | jq -r '.package.name')"
  PREVIOUS_VERSION="$(printf '%s\n' "$METADATA_BEFORE" | jq -r '.package.version')"
  if [[ -z "$PACKAGE_NAME" || "$PACKAGE_NAME" == "null" ]]; then
    fail "package.name is required"
    return 1
  fi
  if [[ -z "$PREVIOUS_VERSION" || "$PREVIOUS_VERSION" == "null" ]]; then
    fail "package.version is required"
    return 1
  fi

  if [[ -z "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(bump_semver "$PREVIOUS_VERSION" "$BUMP_KIND")" || return 1
  fi
  if [[ "$(compare_semver "$TARGET_VERSION" "$PREVIOUS_VERSION")" -le 0 ]]; then
    fail "target version $TARGET_VERSION must be greater than current version $PREVIOUS_VERSION"
    return 1
  fi
  TARGET_TAG="v$TARGET_VERSION"
  PREVIOUS_TAG="$(git -C "$WORK_ROOT" tag --list 'v[0-9]*' --sort=-version:refname | head -n 1)"
  NOTES_FILE="$REPORT_DIR/release-notes-$TARGET_TAG.md"
}

main() {
  parse_args "$@"
  prepare_report_dir
  trap cleanup EXIT

  prepare_workspace || return 1

  info "mode: $MODE"
  info "workspace: $WORK_ROOT"
  if [[ "$SOURCE_DIRTY" == "true" && "$MODE" == "dry-run" ]]; then
    info "source tree is dirty; dry-run clone uses committed HEAD $SOURCE_COMMIT"
  fi

  require_clean_tree_for_execute || return 1

  run_step "Check required tools" bash -c 'command -v git && command -v bau && command -v nimble && command -v gh && command -v jq' || return 1
  run_step "Check GitHub authentication" gh auth status || return 1
  run_step "Check remote exists" git remote get-url "$REMOTE" || return 1

  read_initial_metadata || return 1
  info "release target: $PACKAGE_NAME $PREVIOUS_VERSION -> $TARGET_VERSION ($TARGET_TAG)"

  run_step "Check local tag is unused" bash -c 'if git rev-parse -q --verify "refs/tags/$1" >/dev/null; then echo "tag already exists locally: $1" >&2; exit 1; fi' bash "$TARGET_TAG" || return 1
  run_step "Check remote tag is unused" bash -c 'out="$(git ls-remote --exit-code --tags "$1" "refs/tags/$2" 2>&1)"; code=$?; if [ "$code" -eq 0 ]; then echo "tag already exists on remote $1: $2" >&2; exit 1; fi; if [ "$code" -eq 2 ]; then exit 0; fi; printf "%s\n" "$out" >&2; exit "$code"' bash "$REMOTE" "$TARGET_TAG" || return 1
  run_step "Check GitHub release is unused" bash -c 'out="$(gh release view "$1" 2>&1)"; code=$?; if [ "$code" -eq 0 ]; then echo "GitHub release already exists: $1" >&2; exit 1; fi; if printf "%s\n" "$out" | grep -Eiq "not found|could not resolve|HTTP 404"; then exit 0; fi; printf "%s\n" "$out" >&2; exit "$code"' bash "$TARGET_TAG" || return 1

  run_function_step "Update version files" "update bau.toml and $PACKAGE_NAME.nimble to $TARGET_VERSION" write_version_files || return 1
  run_capture METADATA_AFTER "Read updated metadata" bau metadata --json || return 1
  local updated_version
  updated_version="$(printf '%s\n' "$METADATA_AFTER" | jq -r '.package.version')"
  if [[ "$updated_version" != "$TARGET_VERSION" ]]; then
    fail "metadata version after update is $updated_version, expected $TARGET_VERSION"
    return 1
  fi

  run_step "Refresh dependencies and lock" bau deps sync || return 1
  run_step "Verify locked dependency sync" bau deps sync --locked || return 1
  run_step "Verify dependencies" bau deps verify || return 1
  run_step "Run doctor" bau doctor || return 1
  run_step "Check all targets" bau check --all-targets || return 1
  run_step "Run tests" bau test || return 1
  run_step "Generate docs" bau doc || return 1
  run_step "Inspect package contents" bau package --list --dry-run || return 1
  run_step "Validate Nimble publish" bau publish --dry-run || return 1
  run_step "Build release profile" bau build --profile release || return 1
  run_step "Check release binary version" bash -c 'test -x build/release/bau && build/release/bau version | grep -F "$1"' bash "$TARGET_VERSION" || return 1
  run_function_step "Generate release notes" "generate release notes at $NOTES_FILE" generate_release_notes "$NOTES_FILE" "$TARGET_TAG" "$PREVIOUS_TAG" "$PACKAGE_NAME" "$TARGET_VERSION" || return 1
  run_step "Verify release notes" test -s "$NOTES_FILE" || return 1

  run_step "Stage release changes" git add bau.toml "$PACKAGE_NAME.nimble" bau.lock Readme.md docs || return 1
  run_step "Verify staged release changes" bash -c 'git diff --cached --quiet && { echo "no release changes staged" >&2; exit 1; }; git diff --cached --stat' || return 1
  run_step "Commit release changes" git commit -m "Release $TARGET_TAG" || return 1
  run_step "Create release tag" git tag -a "$TARGET_TAG" -m "Release $TARGET_TAG" || return 1

  if [[ "$MODE" == "dry-run" ]]; then
    run_step "Dry-run push release commit" git push --dry-run "$REMOTE" "HEAD:$BRANCH" || return 1
    run_step "Dry-run push release tag" git push --dry-run "$REMOTE" "refs/tags/$TARGET_TAG" || return 1
    run_step "Dry-run GitHub release command" bash -c 'printf "would run: gh release create %q --title %q --notes-file %q%s\n" "$1" "$1" "$2" "$3"' bash "$TARGET_TAG" "$NOTES_FILE" "$(if [[ "$GITHUB_DRAFT" == "true" ]]; then printf ' --draft'; fi)" || return 1
  else
    run_step "Push release commit" git push "$REMOTE" "HEAD:$BRANCH" || return 1
    run_step "Push release tag" git push "$REMOTE" "refs/tags/$TARGET_TAG" || return 1
    run_function_step "Ensure Nimble package registration" "register $PACKAGE_NAME with Nimble if needed" ensure_nimble_package_registration || return 1
    if [[ "$GITHUB_DRAFT" == "true" ]]; then
      run_step "Create draft GitHub release" gh release create "$TARGET_TAG" --title "$TARGET_TAG" --notes-file "$NOTES_FILE" --draft || return 1
    else
      run_step "Create GitHub release" gh release create "$TARGET_TAG" --title "$TARGET_TAG" --notes-file "$NOTES_FILE" || return 1
    fi
    run_step "Verify remote tag" git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TARGET_TAG" || return 1
    run_step "Verify GitHub release" gh release view "$TARGET_TAG" || return 1
    run_step "Check Nimble version search" bash -c 'nimble search "$1" --ver | grep -F "$2"' bash "$PACKAGE_NAME" "$TARGET_TAG" || return 1
  fi
}

main "$@"
