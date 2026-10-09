#!/usr/bin/env bash
# Runs init and plan, apply, or unlock for a workspace.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${GITHUB_WORKSPACE:-$(pwd)}
cd "$ROOT"

: "${COMMAND:?}"
: "${GIT_SHA:?}"
: "${HEAD_REF:?}"
: "${GITHUB_ACTOR:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_SERVER_URL:?}"
: "${GITHUB_REPOSITORY:?}"

if [[ -n "${TF_EXECUTABLE:-}" ]]; then
  EXECUTABLE=$TF_EXECUTABLE
else
  EXECUTABLE=$(bash "$ROOT/scripts/pipeline.sh" tool)
fi
export EXECUTABLE
case "$EXECUTABLE" in
  terraform | tofu) ;;
  *)
    echo "EXECUTABLE must be terraform or tofu, not '$EXECUTABLE'." >&2
    exit 1
    ;;
esac

RUNNER_TEMP=${RUNNER_TEMP:-/tmp}
OK_FILE="$RUNNER_TEMP/tf-comment-ok.md"
ERR_FILE="$RUNNER_TEMP/tf-comment-err.md"
export LOCK_ETAG_FILE="$RUNNER_TEMP/tf-lock.etag"
export LOCK_STATE_FILE="$RUNNER_TEMP/tf-lock.json"
rm -f "$OK_FILE" "$ERR_FILE" "$LOCK_ETAG_FILE" "$RUNNER_TEMP/tf-lock-held.env"

acquired=0
keep_lock=0

cleanup() {
  if [[ "$acquired" == 1 && "$keep_lock" != 1 ]]; then
    bash "$SCRIPT_DIR/lock.sh" release || true
    rm -f "$RUNNER_TEMP/tf-lock-held.env"
  fi
}
trap cleanup EXIT

write_md() {
  local dest=$1
  local title=$2
  local bodyfile=$3
  python3 - "$dest" "$title" "$bodyfile" <<'PY'
import pathlib, sys
dest, title, bodyfile = sys.argv[1:]
body = pathlib.Path(bodyfile).read_text(encoding="utf-8", errors="replace").rstrip()
limit = 64000
text = f"### {title}\n\n{body}\n"
if len(text) > limit:
    note = "\n\nOutput truncated. The full plan is available as a workflow artifact."
    room = limit - len(title) - len(note) - 8
    text = f"### {title}\n\n{body[:max(0, room)]}{note}\n"
pathlib.Path(dest).write_text(text, encoding="utf-8")
PY
}

write_err() {
  local title=$1
  local text=$2
  local body
  body=$(mktemp)
  printf '%s\n' "$text" >"$body"
  write_md "$ERR_FILE" "$title" "$body"
  rm -f "$body"
}

short_sha() {
  printf '%s' "${1:0:7}"
}

resolve_workspace() {
  if [[ "$COMMAND" == "preview" ]]; then
    bash "$ROOT/scripts/pipeline.sh" preview-workspace "$HEAD_REF"
  else
    printf '%s\n' "${TF_WORKSPACE:?}"
  fi
}

parse_backend() {
  local backend=$1
  local name=$2
  sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$backend" | head -n 1
}

prepare_lock_env() {
  local ws=$1
  local backend="environments/${ws}.backend.tfvars"
  if [[ ! -f "$backend" ]]; then
    write_err "Terraform ${COMMAND} (\`${ws}\`)" "Backend file is missing: \`${backend}\`."
    exit 1
  fi
  local bucket key region key_dir
  bucket=$(parse_backend "$backend" bucket)
  key=$(parse_backend "$backend" key)
  region=$(parse_backend "$backend" region)
  if [[ -z "$bucket" || -z "$key" || -z "$region" ]]; then
    write_err "Terraform ${COMMAND} (\`${ws}\`)" "\`bucket\`, \`key\`, or \`region\` is missing in \`${backend}\`."
    exit 1
  fi
  key_dir=$(dirname "$key")
  if [[ "$key_dir" == "." ]]; then
    LOCK_KEY="pr-locks/${ws}.json"
  else
    LOCK_KEY="${key_dir}/pr-locks/${ws}.json"
  fi
  export LOCK_BUCKET="$bucket"
  export LOCK_KEY
  export LOCK_REGION="$region"
  export LOCK_SHA="$GIT_SHA"
  export LOCK_USER="$GITHUB_ACTOR"
  export LOCK_REF="$HEAD_REF"
  export LOCK_PR="${PR_NUMBER:-}"
}

save_lock_env() {
  {
    printf 'LOCK_BUCKET=%q\n' "$LOCK_BUCKET"
    printf 'LOCK_KEY=%q\n' "$LOCK_KEY"
    printf 'LOCK_REGION=%q\n' "$LOCK_REGION"
    printf 'LOCK_SHA=%q\n' "$LOCK_SHA"
    printf 'LOCK_USER=%q\n' "$LOCK_USER"
    printf 'LOCK_REF=%q\n' "$LOCK_REF"
    printf 'LOCK_PR=%q\n' "${LOCK_PR:-}"
    printf 'LOCK_ETAG_FILE=%q\n' "$LOCK_ETAG_FILE"
    printf 'LOCK_STATE_FILE=%q\n' "$LOCK_STATE_FILE"
  } >"$RUNNER_TEMP/tf-lock-held.env"
}

holder_text() {
  local ws=$1
  local pr sha user ref url
  pr=$(jq -r '.pr // empty' "$LOCK_STATE_FILE")
  sha=$(jq -r '.sha' "$LOCK_STATE_FILE")
  user=$(jq -r '.user' "$LOCK_STATE_FILE")
  ref=$(jq -r '.ref' "$LOCK_STATE_FILE")
  if [[ -n "$pr" ]]; then
    url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${pr}"
    printf 'Workspace `%s` is locked by [PR #%s](%s) (commit `%s`, %s).\n\nThis run did not create a new plan. Run `/tf unlock` in the locking PR to release it, or wait for its `/tf apply`.\n' \
      "$ws" "$pr" "$url" "$(short_sha "$sha")" "$user"
  else
    printf 'Workspace `%s` is locked by the push to `%s` (commit `%s`, %s).\n\nRun `/tf unlock` on the pull request of that branch to release it.\n' \
      "$ws" "$ref" "$(short_sha "$sha")" "$user"
  fi
}

run_lock() {
  local lock_cmd=$1
  local err status
  err=$(mktemp)
  set +e
  bash "$SCRIPT_DIR/lock.sh" "$lock_cmd" 2>"$err"
  status=$?
  set -e
  if [[ -s "$err" ]]; then
    cat "$err" >&2
  fi
  rm -f "$err"
  printf '%s\n' "$status" >"$RUNNER_TEMP/tf-lock.rc"
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
}

ensure_preview_files() {
  local ws=$1
  local tfvars="environments/${ws}.tfvars"
  local backend="environments/${ws}.backend.tfvars"
  if [[ "$ws" != preview-* ]]; then
    return 0
  fi
  if [[ -f "$tfvars" && -f "$backend" ]]; then
    return 0
  fi
  local log body
  log=$(mktemp)
  scripts/tf -e "$ws" init >"$log" 2>&1 || true
  cat "$log"
  body=$(mktemp)
  {
    cat "$log"
    printf '\nThe files must be committed on the branch. This run applied nothing.\n'
  } >"$body"
  write_md "$ERR_FILE" "Terraform preview (\`${ws}\`)" "$body"
  rm -f "$log" "$body"
  exit 1
}

write_secrets() {
  local ws=$1
  if [[ -z "${TF_SECRETS_TFVARS:-}" ]]; then
    return 0
  fi
  umask 077
  printf '%s\n' "$TF_SECRETS_TFVARS" >"environments/${ws}.secrets.tfvars"
}

run_tf() {
  local log=$1
  shift
  set +e
  scripts/tf "$@" >"$log" 2>&1
  local status=$?
  set -e
  cat "$log"
  return "$status"
}

fenced_log() {
  local intro=$1
  local log=$2
  local dest=$3
  local fence="~~~~"
  local content
  content=$(cat "$log")
  while [[ "$content" == *"$fence"* ]]; do
    fence="${fence}~"
  done
  {
    printf '%s\n\n' "$intro"
    printf '%s\n' "$fence"
    printf '%s\n' "$content"
    printf '%s\n' "$fence"
  } >"$dest"
}

comment_plan() {
  local ws=$1
  local show=$2
  local body
  body=$(mktemp)
  fenced_log "$(printf 'Commit `%s`\nArtifact `%s`' "$(short_sha "$GIT_SHA")" "tfplan-${PR_NUMBER}-${GIT_SHA}-${ws}")" "$show" "$body"
  write_md "$OK_FILE" "Terraform plan (\`${ws}\`)" "$body"
  rm -f "$body"
}

comment_apply() {
  local ws=$1
  local log=$2
  local body
  body=$(mktemp)
  fenced_log "$(printf 'Plan for commit `%s` was applied.' "$(short_sha "$GIT_SHA")")" "$log" "$body"
  write_md "$OK_FILE" "Terraform apply (\`${ws}\`)" "$body"
  rm -f "$body"
}

download_plan() {
  local ws=$1
  local name="tfplan-${PR_NUMBER}-${GIT_SHA}-${ws}"
  local tmp id found meta status
  tmp=$(mktemp -d)
  set +e
  meta=$(gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${name}&per_page=100" 2>&1)
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$meta" >&2
    rm -rf "$tmp"
    return 1
  fi
  id=$(jq -r --arg name "$name" '[.artifacts[] | select(.name == $name and .expired == false)] | sort_by(.created_at) | last | .id // empty' <<<"$meta")
  if [[ -z "$id" || "$id" == "null" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  if ! gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" >"$tmp/plan.zip"; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$tmp/unpack"
  if ! unzip -q "$tmp/plan.zip" -d "$tmp/unpack"; then
    rm -rf "$tmp"
    return 1
  fi
  found=$(find "$tmp/unpack" -type f -name '*.tfplan' -print -quit)
  if [[ -z "$found" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p environments
  cp "$found" "environments/${ws}.tfplan"
  rm -rf "$tmp"
}

fail_lock_status() {
  local ws=$1
  local status=$2
  local title=$3
  case "$status" in
    2)
      write_err "$title" "$(holder_text "$ws")"
      ;;
    3)
      write_err "$title" "$(printf 'An apply is already running for workspace `%s`. Wait for it to finish, or release the lock with `/tf unlock`.\n' "$ws")"
      ;;
    4)
      write_err "$title" "$(printf 'There is no lock for workspace `%s`. Run `/tf plan` first.\n' "$ws")"
      ;;
    5)
      local old
      old=$(jq -r '.sha' "$LOCK_STATE_FILE")
      write_err "$title" "$(printf 'The lock belongs to commit `%s`, but the current commit is `%s`. Please run `/tf plan` again.\n' "$(short_sha "$old")" "$(short_sha "$GIT_SHA")")"
      ;;
    *)
      write_err "$title" "The workspace lock could not be set or checked."
      ;;
  esac
  exit 1
}

do_plan() {
  local ws=$1
  local log show status=0
  if run_lock acquire; then
    :
  else
    status=$(tr -d '[:space:]' <"$RUNNER_TEMP/tf-lock.rc")
    fail_lock_status "$ws" "$status" "Terraform plan (\`${ws}\`)"
  fi
  acquired=1
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init; then
    write_err "Terraform plan (\`${ws}\`)" "$(cat "$log")"
    rm -f "$log"
    exit 1
  fi
  if ! run_tf "$log" -e "$ws" plan; then
    write_err "Terraform plan (\`${ws}\`)" "$(cat "$log")"
    rm -f "$log"
    exit 1
  fi
  show=$(mktemp)
  if ! "$EXECUTABLE" show -no-color "environments/${ws}.tfplan" >"$show" 2>&1; then
    write_err "Terraform plan (\`${ws}\`)" "$(cat "$show")"
    rm -f "$log" "$show"
    exit 1
  fi
  comment_plan "$ws" "$show"
  rm -f "$log" "$show"
  save_lock_env
  keep_lock=1
  {
    echo "upload_plan=true"
    echo "artifact_name<<EOF"
    echo "tfplan-${PR_NUMBER}-${GIT_SHA}-${ws}"
    echo "EOF"
    echo "plan_file<<EOF"
    echo "environments/${ws}.tfplan"
    echo "EOF"
  } >>"$GITHUB_OUTPUT"
}

do_apply() {
  local ws=$1
  local log status=0
  if run_lock begin-apply; then
    :
  else
    status=$(tr -d '[:space:]' <"$RUNNER_TEMP/tf-lock.rc")
    fail_lock_status "$ws" "$status" "Terraform apply (\`${ws}\`)"
  fi
  acquired=1
  keep_lock=1
  if ! download_plan "$ws"; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "Terraform apply (\`${ws}\`)" "$(printf 'No saved plan for commit `%s` in workspace `%s`. Run `/tf plan` first.\n' "$(short_sha "$GIT_SHA")" "$ws")"
    exit 1
  fi
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "Terraform apply (\`${ws}\`)" "$(cat "$log")"
    rm -f "$log"
    exit 1
  fi
  if ! run_tf "$log" -e "$ws" apply; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "Terraform apply (\`${ws}\`)" "$(cat "$log")"
    rm -f "$log"
    exit 1
  fi
  bash "$SCRIPT_DIR/lock.sh" finish-apply
  acquired=0
  comment_apply "$ws" "$log"
  rm -f "$log"
  echo "upload_plan=false" >>"$GITHUB_OUTPUT"
}

do_unlock() {
  local ws=$1
  local status=0
  local body
  if run_lock unlock; then
    :
  else
    status=$(tr -d '[:space:]' <"$RUNNER_TEMP/tf-lock.rc")
    fail_lock_status "$ws" "$status" "Terraform unlock (\`${ws}\`)"
  fi
  body=$(mktemp)
  printf 'The lock for workspace `%s` is released. The saved plan can no longer be applied.\n' "$ws" >"$body"
  write_md "$OK_FILE" "Terraform unlock (\`${ws}\`)" "$body"
  rm -f "$body"
  echo "upload_plan=false" >>"$GITHUB_OUTPUT"
}

do_preview() {
  local ws=$1
  local log status=0
  if run_lock acquire; then
    :
  else
    status=$(tr -d '[:space:]' <"$RUNNER_TEMP/tf-lock.rc")
  fi
  if [[ $status -ne 0 ]]; then
    echo "Workspace ${ws} is locked. The push is not applied." >&2
    if [[ -f "$LOCK_STATE_FILE" ]]; then
      holder_text "$ws" >&2
    fi
    exit 1
  fi
  acquired=1
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init; then
    rm -f "$log"
    exit 1
  fi
  if ! run_tf "$log" -e "$ws" plan; then
    rm -f "$log"
    exit 1
  fi
  if ! run_lock begin-apply; then
    exit 1
  fi
  keep_lock=1
  if ! run_tf "$log" -e "$ws" apply; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    rm -f "$log"
    exit 1
  fi
  bash "$SCRIPT_DIR/lock.sh" finish-apply
  acquired=0
  rm -f "$log"
  echo "upload_plan=false" >>"$GITHUB_OUTPUT"
  echo "Preview ${ws} was applied ($(short_sha "$GIT_SHA"))."
}

ws=$(resolve_workspace)
echo "Workspace: ${ws}"

if [[ "$COMMAND" != "unlock" ]]; then
  ensure_preview_files "$ws"
fi

prepare_lock_env "$ws"

case "$COMMAND" in
  plan) do_plan "$ws" ;;
  apply) do_apply "$ws" ;;
  unlock) do_unlock "$ws" ;;
  preview) do_preview "$ws" ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
