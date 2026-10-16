#!/usr/bin/env bash
# Reads pipeline.json and resolves the tool, workspace, and approval.
set -euo pipefail

require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  cat <<'EOF' >&2
jq is missing. It is needed to read pipeline.json.
macOS:         brew install jq
Debian/Ubuntu: sudo apt-get install jq
EOF
  exit 1
}

require_jq

if [[ -n "${PIPELINE_ROOT:-}" ]]; then
  ROOT=$PIPELINE_ROOT
elif ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  :
else
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

CONFIG=${PIPELINE_CONFIG:-$ROOT/pipeline.json}

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing: $CONFIG" >&2
  exit 1
fi

die() {
  echo "$*" >&2
  exit 1
}

NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'

valid_workspace_name() {
  local name=$1
  [[ "$name" != "default" && "$name" =~ $NAME_RE ]]
}

tool_value() {
  jq -r '.tool // "terraform"' "$CONFIG"
}

preview_mode() {
  jq -r '.preview.mode' "$CONFIG"
}

preview_prefix() {
  jq -r '.preview.prefix' "$CONFIG"
}

preview_suffix() {
  jq -r '.preview.suffix' "$CONFIG"
}

preview_label() {
  jq -r '.preview.label' "$CONFIG"
}

stage_for_branch() {
  local b=$1
  jq -r --arg b "$b" '[.environments[] | select(.branch == $b) | .name] | first // empty' "$CONFIG"
}

# "/" becomes "--". Segments must not be empty, start or end with "-", or
# contain "--", so that two different branches never share a workspace.
branch_slug() {
  local ref=$1
  if [[ -z "$ref" || "$ref" == /* || "$ref" == */ || "$ref" == *//* ||
    "$ref" == *--* || "$ref" == -* || "$ref" == *- || "$ref" == *-/* || "$ref" == */-* ]]; then
    echo "Branch '$ref' cannot become a preview environment." >&2
    echo "Path segments must not be empty, start or end with '-', or contain '--'." >&2
    return 1
  fi
  printf '%s\n' "${ref//\//--}"
}

# stdout: the workspace on a match.
# Exit 2: not a preview. Exit 1: a preview, but invalid.
try_preview() {
  local ref=$1
  local mode prefix suffix label rest slug labels ws
  mode=$(preview_mode)
  case "$mode" in
    off)
      return 2
      ;;
    prefix)
      prefix=$(preview_prefix)
      [[ "$ref" == "$prefix"* ]] || return 2
      rest=${ref#"$prefix"}
      if [[ -z "$rest" || "$rest" == *"/"* ]]; then
        echo "Branch '$ref' is not a valid preview environment." >&2
        echo "Exactly one level after '${prefix}' is allowed." >&2
        return 1
      fi
      slug=$rest
      ;;
    suffix)
      suffix=$(preview_suffix)
      [[ -n "$suffix" && "$ref" == *"$suffix" ]] || return 2
      rest=${ref%"$suffix"}
      slug=$(branch_slug "$rest") || return 1
      ;;
    label)
      label=$(preview_label)
      labels=${PIPELINE_LABELS:-[]}
      if ! jq -e . >/dev/null <<<"$labels"; then
        echo "PIPELINE_LABELS is not valid JSON." >&2
        return 1
      fi
      if ! jq -e --arg l "$label" 'index($l) != null' >/dev/null <<<"$labels"; then
        return 2
      fi
      slug=$(branch_slug "$ref") || return 1
      ;;
    *)
      echo "preview.mode '$mode' is invalid." >&2
      return 1
      ;;
  esac
  ws="preview-${slug}"
  if ! valid_workspace_name "$ws" || [[ "$slug" == "" ]]; then
    echo "Environment '$ws' is invalid." >&2
    return 1
  fi
  printf '%s\n' "$ws"
}

allowed_hint() {
  local mode
  mode=$(preview_mode)
  echo "Allowed:" >&2
  jq -r '.environments[] | "  \(.branch) -> \(.name)"' "$CONFIG" >&2
  case "$mode" in
    prefix)
      echo "  $(preview_prefix)<name> -> preview-<name>" >&2
      ;;
    suffix)
      echo "  <branch>$(preview_suffix) -> preview-<slug>" >&2
      ;;
    label)
      echo "  Label '$(preview_label)' on a pull request -> preview-<slug>" >&2
      ;;
    off) ;;
  esac
}

take_preview_or() {
  local ref=$1
  local ws status
  set +e
  ws=$(try_preview "$ref")
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s\n' "$ws"
    return 0
  fi
  if [[ $status -ne 2 ]]; then
    return "$status"
  fi
  return 2
}

workspace_of_ref() {
  local ref=$1
  local ws status
  set +e
  ws=$(take_preview_or "$ref")
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s\n' "$ws"
    return 0
  fi
  if [[ $status -ne 2 ]]; then
    return "$status"
  fi
  ws=$(stage_for_branch "$ref")
  if [[ -z "$ws" ]]; then
    if [[ "$ref" == "HEAD" ]]; then
      echo "Detached HEAD. Pass the environment with -e or --env." >&2
    else
      echo "Branch '$ref' is not mapped to an environment." >&2
      allowed_hint
    fi
    return 1
  fi
  printf '%s\n' "$ws"
}

cmd_workspace_pr() {
  local head=$1
  local base=$2
  local ws status
  set +e
  ws=$(take_preview_or "$head")
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s\n' "$ws"
    return 0
  fi
  if [[ $status -ne 2 ]]; then
    return "$status"
  fi
  ws=$(stage_for_branch "$base")
  if [[ -z "$ws" ]]; then
    echo "Branch '$base' is not mapped to an environment." >&2
    allowed_hint
    return 1
  fi
  printf '%s\n' "$ws"
}

cmd_preview_workspace() {
  local ref=$1
  local ws status
  if [[ "$(preview_mode)" == "label" ]]; then
    PIPELINE_LABELS=$(jq -nc --arg l "$(preview_label)" '[$l]')
  fi
  set +e
  ws=$(take_preview_or "$ref")
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s\n' "$ws"
    return 0
  fi
  echo "Branch '$ref' is not a preview environment." >&2
  allowed_hint
  return 1
}

cmd_protected() {
  local name=$1
  jq -r --arg n "$name" '([.environments[] | select(.name == $n) | .protected] | first) // false' "$CONFIG"
}

# GitHub environment for a workspace. All previews share "preview".
cmd_environment() {
  local name=$1
  if [[ "$name" == preview-* ]]; then
    printf 'preview\n'
  else
    printf '%s\n' "$name"
  fi
}

secret_name_for() {
  local env=$1
  env=$(printf '%s' "$env" | tr '[:lower:]-' '[:upper:]_')
  printf 'TF_SECRETS_TFVARS_%s\n' "$env"
}

cmd_secret_name() {
  secret_name_for "$(cmd_environment "$1")"
}

# Path of an env file, relative to the root. Previews fall back to the
# shared preview.<kind> file when no workspace-specific file exists.
cmd_env_file() {
  local name=$1 kind=$2 ext own shared
  case "$kind" in
    tfvars) ext=tfvars ;;
    backend) ext=backend.tfvars ;;
    secrets) ext=secrets.tfvars ;;
    *) die "Kind must be tfvars, backend, or secrets, not '$kind'." ;;
  esac
  own="environments/${name}.${ext}"
  shared="environments/preview.${ext}"
  if [[ "$name" == preview-* && ! -f "$ROOT/$own" && -f "$ROOT/$shared" ]]; then
    printf '%s\n' "$shared"
  else
    printf '%s\n' "$own"
  fi
}

cmd_validate() {
  local name=$1
  local mode
  if [[ "$name" == "default" ]]; then
    echo "Environment 'default' is not allowed." >&2
    return 1
  fi
  if ! valid_workspace_name "$name"; then
    echo "Environment '$name' is invalid." >&2
    return 1
  fi
  if [[ -n "$(jq -r --arg n "$name" '[.environments[] | select(.name == $n) | .name] | first // empty' "$CONFIG")" ]]; then
    return 0
  fi
  mode=$(preview_mode)
  if [[ "$mode" != "off" && "$name" == preview-* && "$name" != "preview-" ]]; then
    return 0
  fi
  echo "Environment '$name' is not allowed." >&2
  allowed_hint
  return 1
}

cmd_tool() {
  local tool
  tool=$(tool_value)
  case "$tool" in
    terraform | tofu)
      printf '%s\n' "$tool"
      ;;
    *)
      echo "tool must be terraform or tofu, not '$tool'." >&2
      return 1
      ;;
  esac
}

branch_is_preview_pattern() {
  local branch=$1
  local mode prefix suffix
  mode=$(preview_mode)
  case "$mode" in
    prefix)
      prefix=$(preview_prefix)
      [[ "$branch" == "$prefix"* ]]
      ;;
    suffix)
      suffix=$(preview_suffix)
      [[ -n "$suffix" && "$branch" == *"$suffix" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

cmd_check() {
  local tool mode prefix suffix label count names branches secrets name branch protected
  tool=$(tool_value)
  case "$tool" in
    terraform | tofu) ;;
    *) die "tool must be terraform or tofu, not '$tool'." ;;
  esac
  mode=$(preview_mode)
  case "$mode" in
    off | prefix | suffix | label) ;;
    *) die "preview.mode '$mode' is invalid. Allowed: off, prefix, suffix, label." ;;
  esac
  if [[ "$mode" == "prefix" ]]; then
    prefix=$(preview_prefix)
    [[ -n "$prefix" && "$prefix" == */ && "$prefix" != *"*"* && "$prefix" != *'"'* ]] || die "preview.prefix must end with / and must not contain wildcards."
  fi
  if [[ "$mode" == "suffix" ]]; then
    suffix=$(preview_suffix)
    [[ -n "$suffix" && "$suffix" != *"/"* && "$suffix" != *"*"* && "$suffix" != *'"'* ]] || die "preview.suffix is invalid."
  fi
  if [[ "$mode" == "label" ]]; then
    label=$(preview_label)
    [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "preview.label is invalid."
  fi
  count=$(jq '.environments | length' "$CONFIG")
  [[ "$count" -ge 1 ]] || die "At least one environment is required."
  while IFS=$'\t' read -r name branch protected; do
    [[ "$name" =~ $NAME_RE ]] || die "Environment name '$name' is invalid."
    [[ "$name" != "default" ]] || die "Environment name 'default' is not allowed."
    [[ "$name" != "preview" && "$name" != preview-* ]] || die "Environment name '$name' collides with preview workspaces."
    [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "Branch '$branch' is invalid."
    [[ "$branch" != *..* && "$branch" != /* && "$branch" != */ && "$branch" != *//* ]] || die "Branch '$branch' is invalid."
    [[ "$protected" == "true" || "$protected" == "false" ]] || die "protected for '$name' must be true or false."
    if branch_is_preview_pattern "$branch"; then
      die "Branch '$branch' matches the preview rule and cannot be an environment."
    fi
  done < <(jq -r '.environments[] | [.name, .branch, (.protected | tostring)] | @tsv' "$CONFIG")
  names=$(jq -r '.environments[].name' "$CONFIG" | sort | uniq -d)
  branches=$(jq -r '.environments[].branch' "$CONFIG" | sort | uniq -d)
  [[ -z "$names" ]] || die "Duplicate environment name: $names"
  [[ -z "$branches" ]] || die "Duplicate branch: $branches"
  secrets=$(jq -r '.environments[].name' "$CONFIG" | while IFS= read -r name; do secret_name_for "$name"; done | sort | uniq -d)
  [[ -z "$secrets" ]] || die "Environment names map to the same secret: $secrets"
}

cmd_mapping() {
  local mode
  echo "tool: $(tool_value)"
  jq -r '.environments[] | "\(.branch) -> \(.name)\(if .protected then " (protected)" else "" end)"' "$CONFIG"
  mode=$(preview_mode)
  case "$mode" in
    off) echo "preview: off" ;;
    prefix) echo "preview: prefix $(preview_prefix)<name> -> preview-<name>" ;;
    suffix) echo "preview: suffix <branch>$(preview_suffix) -> preview-<slug>" ;;
    label) echo "preview: label $(preview_label) on a pull request" ;;
  esac
}

case "${1:-}" in
  tool)
    cmd_tool
    ;;
  protected)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh protected <workspace>"
    cmd_protected "$2"
    ;;
  environment)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh environment <workspace>"
    cmd_environment "$2"
    ;;
  secret-name)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh secret-name <workspace>"
    cmd_secret_name "$2"
    ;;
  env-file)
    [[ $# -eq 3 ]] || die "Usage: pipeline.sh env-file <workspace> <tfvars|backend|secrets>"
    cmd_env_file "$2" "$3"
    ;;
  validate)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh validate <workspace>"
    cmd_validate "$2"
    ;;
  workspace)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh workspace <ref>"
    workspace_of_ref "$2"
    ;;
  workspace-pr)
    [[ $# -eq 3 ]] || die "Usage: pipeline.sh workspace-pr <head> <base>"
    cmd_workspace_pr "$2" "$3"
    ;;
  preview-workspace)
    [[ $# -eq 2 ]] || die "Usage: pipeline.sh preview-workspace <ref>"
    cmd_preview_workspace "$2"
    ;;
  check)
    cmd_check
    ;;
  mapping)
    cmd_mapping
    ;;
  *)
    die "Usage: pipeline.sh <tool|protected|environment|secret-name|env-file|validate|workspace|workspace-pr|preview-workspace|check|mapping>"
    ;;
esac
