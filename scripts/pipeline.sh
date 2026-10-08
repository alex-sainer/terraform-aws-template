#!/usr/bin/env bash
# Liest pipeline.json und löst Tool, Workspace und Freigabe auf.
set -euo pipefail

require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  cat <<'EOF' >&2
jq fehlt. pipeline.json wird damit gelesen.
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
  echo "Fehlt: $CONFIG" >&2
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

# stdout: Workspace bei Treffer.
# Exit 2: kein Preview. Exit 1: Preview, aber ungültig.
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
        echo "Branch '$ref' ist kein gültiges Preview-Environment." >&2
        echo "Erlaubt ist genau eine Ebene nach '${prefix}'." >&2
        return 1
      fi
      slug=$rest
      ;;
    suffix)
      suffix=$(preview_suffix)
      [[ -n "$suffix" && "$ref" == *"$suffix" ]] || return 2
      rest=${ref%"$suffix"}
      rest=${rest%/}
      if [[ -z "$rest" ]]; then
        echo "Branch '$ref' ist kein gültiges Preview-Environment." >&2
        return 1
      fi
      slug=${rest//\//-}
      ;;
    label)
      label=$(preview_label)
      labels=${PIPELINE_LABELS:-[]}
      if ! jq -e . >/dev/null <<<"$labels"; then
        echo "PIPELINE_LABELS ist kein JSON." >&2
        return 1
      fi
      if ! jq -e --arg l "$label" 'index($l) != null' >/dev/null <<<"$labels"; then
        return 2
      fi
      if [[ -z "$ref" ]]; then
        echo "Branch '$ref' ist kein gültiges Preview-Environment." >&2
        return 1
      fi
      slug=${ref//\//-}
      ;;
    *)
      echo "preview.mode '$mode' ist ungültig." >&2
      return 1
      ;;
  esac
  ws="preview-${slug}"
  if ! valid_workspace_name "$ws" || [[ "$slug" == "" ]]; then
    echo "Environment '$ws' ist ungültig." >&2
    return 1
  fi
  printf '%s\n' "$ws"
}

allowed_hint() {
  local mode
  mode=$(preview_mode)
  echo "Erlaubt:" >&2
  jq -r '.environments[] | "  \(.branch) -> \(.name)"' "$CONFIG" >&2
  case "$mode" in
    prefix)
      echo "  $(preview_prefix)<name> -> preview-<name>" >&2
      ;;
    suffix)
      echo "  <branch>$(preview_suffix) -> preview-<slug>" >&2
      ;;
    label)
      echo "  Label '$(preview_label)' am Pull Request -> preview-<slug>" >&2
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
      echo "Detached HEAD. Environment mit -e oder --env angeben." >&2
    else
      echo "Branch '$ref' ist keinem Environment zugeordnet." >&2
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
    echo "Branch '$base' ist keinem Environment zugeordnet." >&2
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
  echo "Branch '$ref' ist kein Preview-Environment." >&2
  allowed_hint
  return 1
}

cmd_protected() {
  local name=$1
  jq -r --arg n "$name" '([.environments[] | select(.name == $n) | .protected] | first) // false' "$CONFIG"
}

cmd_validate() {
  local name=$1
  local mode
  if [[ "$name" == "default" ]]; then
    echo "Environment 'default' ist nicht erlaubt." >&2
    return 1
  fi
  if ! valid_workspace_name "$name"; then
    echo "Environment '$name' ist ungültig." >&2
    return 1
  fi
  if [[ -n "$(jq -r --arg n "$name" '[.environments[] | select(.name == $n) | .name] | first // empty' "$CONFIG")" ]]; then
    return 0
  fi
  mode=$(preview_mode)
  if [[ "$mode" != "off" && "$name" == preview-* && "$name" != "preview-" ]]; then
    return 0
  fi
  echo "Environment '$name' ist nicht erlaubt." >&2
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
      echo "tool muss terraform oder tofu sein, nicht '$tool'." >&2
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
  local tool mode prefix suffix label count names branches name branch protected
  tool=$(tool_value)
  case "$tool" in
    terraform | tofu) ;;
    *) die "tool muss terraform oder tofu sein, nicht '$tool'." ;;
  esac
  mode=$(preview_mode)
  case "$mode" in
    off | prefix | suffix | label) ;;
    *) die "preview.mode '$mode' ist ungültig. Erlaubt: off, prefix, suffix, label." ;;
  esac
  if [[ "$mode" == "prefix" ]]; then
    prefix=$(preview_prefix)
    [[ -n "$prefix" && "$prefix" == */ && "$prefix" != *"*"* && "$prefix" != *'"'* ]] || die "preview.prefix muss auf / enden und darf keine Platzhalter enthalten."
  fi
  if [[ "$mode" == "suffix" ]]; then
    suffix=$(preview_suffix)
    [[ -n "$suffix" && "$suffix" != *"/"* && "$suffix" != *"*"* && "$suffix" != *'"'* ]] || die "preview.suffix ist ungültig."
  fi
  if [[ "$mode" == "label" ]]; then
    label=$(preview_label)
    [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "preview.label ist ungültig."
  fi
  count=$(jq '.environments | length' "$CONFIG")
  [[ "$count" -ge 1 ]] || die "Mindestens eine Stage ist nötig."
  while IFS=$'\t' read -r name branch protected; do
    [[ "$name" =~ $NAME_RE ]] || die "Stage-Name '$name' ist ungültig."
    [[ "$name" != "default" ]] || die "Stage-Name 'default' ist nicht erlaubt."
    [[ "$name" != preview-* ]] || die "Stage-Name '$name' kollidiert mit Preview-Workspaces."
    [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "Branch '$branch' ist ungültig."
    [[ "$branch" != *..* && "$branch" != /* && "$branch" != */ && "$branch" != *//* ]] || die "Branch '$branch' ist ungültig."
    [[ "$protected" == "true" || "$protected" == "false" ]] || die "protected für '$name' muss true oder false sein."
    if branch_is_preview_pattern "$branch"; then
      die "Branch '$branch' trifft die Preview-Regel und kann keine Stage sein."
    fi
  done < <(jq -r '.environments[] | [.name, .branch, (.protected | tostring)] | @tsv' "$CONFIG")
  names=$(jq -r '.environments[].name' "$CONFIG" | sort | uniq -d)
  branches=$(jq -r '.environments[].branch' "$CONFIG" | sort | uniq -d)
  [[ -z "$names" ]] || die "Stage-Name mehrfach: $names"
  [[ -z "$branches" ]] || die "Branch mehrfach: $branches"
}

cmd_mapping() {
  local mode
  echo "tool: $(tool_value)"
  jq -r '.environments[] | "\(.branch) -> \(.name)\(if .protected then " (geschützt)" else "" end)"' "$CONFIG"
  mode=$(preview_mode)
  case "$mode" in
    off) echo "preview: aus" ;;
    prefix) echo "preview: Prefix $(preview_prefix)<name> -> preview-<name>" ;;
    suffix) echo "preview: Suffix <branch>$(preview_suffix) -> preview-<slug>" ;;
    label) echo "preview: Label $(preview_label) am Pull Request" ;;
  esac
}

case "${1:-}" in
  tool)
    cmd_tool
    ;;
  protected)
    [[ $# -eq 2 ]] || die "Aufruf: pipeline.sh protected <workspace>"
    cmd_protected "$2"
    ;;
  validate)
    [[ $# -eq 2 ]] || die "Aufruf: pipeline.sh validate <workspace>"
    cmd_validate "$2"
    ;;
  workspace)
    [[ $# -eq 2 ]] || die "Aufruf: pipeline.sh workspace <ref>"
    workspace_of_ref "$2"
    ;;
  workspace-pr)
    [[ $# -eq 3 ]] || die "Aufruf: pipeline.sh workspace-pr <head> <base>"
    cmd_workspace_pr "$2" "$3"
    ;;
  preview-workspace)
    [[ $# -eq 2 ]] || die "Aufruf: pipeline.sh preview-workspace <ref>"
    cmd_preview_workspace "$2"
    ;;
  check)
    cmd_check
    ;;
  mapping)
    cmd_mapping
    ;;
  *)
    die "Aufruf: pipeline.sh <tool|protected|validate|workspace|workspace-pr|preview-workspace|check|mapping>"
    ;;
esac
