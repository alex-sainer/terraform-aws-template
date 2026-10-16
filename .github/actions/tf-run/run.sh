#!/usr/bin/env bash
# Runs init and plan, apply, unlock, preview, release, or destroy for a workspace.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${GITHUB_WORKSPACE:-$(pwd)}
cd "$ROOT"

: "${COMMAND:?}"
: "${GIT_SHA:?}"
: "${HEAD_REF:?}"
: "${GITHUB_ACTOR:?}"
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
rm -f "$OK_FILE" "$ERR_FILE" "$LOCK_ETAG_FILE" "$LOCK_STATE_FILE"

acquired=0
keep_lock=0

cleanup() {
  if [[ "$acquired" == 1 && "$keep_lock" != 1 ]]; then
    bash "$SCRIPT_DIR/lock.sh" release || true
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
    note = "\n\nOutput truncated. The Actions log contains the full output."
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

write_ok() {
  local title=$1
  local text=$2
  local body
  body=$(mktemp)
  printf '%s\n' "$text" >"$body"
  write_md "$OK_FILE" "$title" "$body"
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
  local backend
  backend=$(bash "$ROOT/scripts/pipeline.sh" env-file "$ws" backend)
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
    key_dir=""
  else
    key_dir="${key_dir}/"
  fi
  export LOCK_BUCKET="$bucket"
  export LOCK_KEY="${key_dir}pr-locks/${ws}.json"
  export LOCK_REGION="$region"
  export LOCK_SHA="$GIT_SHA"
  export LOCK_USER="$GITHUB_ACTOR"
  export LOCK_REF="$HEAD_REF"
  export LOCK_PR="${PR_NUMBER:-}"
  PLAN_KEY="${key_dir}pr-plans/${ws}.tfplan"
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
    printf 'Workspace `%s` is locked by [PR #%s](%s) (commit `%s`, %s).\n\nThis run did not create a new plan. Run `/tf unlock` in the locking PR to release it, or wait for its `/tf apply`. Closing that PR releases the lock too.\n' \
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
  LOCK_RC=$status
  return "$status"
}

ensure_env_files() {
  local ws=$1
  local tfvars backend
  tfvars=$(bash "$ROOT/scripts/pipeline.sh" env-file "$ws" tfvars)
  backend=$(bash "$ROOT/scripts/pipeline.sh" env-file "$ws" backend)
  if [[ -f "$tfvars" && -f "$backend" ]]; then
    return 0
  fi
  write_err "Terraform ${COMMAND} (\`${ws}\`)" "$(printf 'Missing on this commit: `%s` or `%s`. This run applied nothing.\n' "$tfvars" "$backend")"
  exit 1
}

write_secrets() {
  local ws=$1
  if [[ -z "${TF_SECRETS_TFVARS:-}" ]]; then
    return 0
  fi
  (
    umask 077
    printf '%s\n' "$TF_SECRETS_TFVARS" >"environments/${ws}.secrets.tfvars"
  )
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

comment_log() {
  local title=$1
  local intro=$2
  local log=$3
  local body
  body=$(mktemp)
  fenced_log "$intro" "$log" "$body"
  write_md "$OK_FILE" "$title" "$body"
  rm -f "$body"
}

s3() {
  aws s3api "$@" --region "$LOCK_REGION" --output json
}

upload_plan() {
  local ws=$1
  s3 put-object \
    --bucket "$LOCK_BUCKET" \
    --key "$PLAN_KEY" \
    --body "environments/${ws}.tfplan" \
    --server-side-encryption AES256 \
    --metadata "$(jq -nc --arg sha "$GIT_SHA" --arg pr "${PR_NUMBER:-}" '{sha: $sha, pr: $pr}')" >/dev/null
}

# Downloads the plan only when it belongs to this pull request and commit.
download_plan() {
  local ws=$1
  local meta sha pr
  mkdir -p environments
  if ! meta=$(s3 get-object --bucket "$LOCK_BUCKET" --key "$PLAN_KEY" "environments/${ws}.tfplan" 2>/dev/null); then
    return 1
  fi
  sha=$(jq -r '.Metadata.sha // empty' <<<"$meta")
  pr=$(jq -r '.Metadata.pr // empty' <<<"$meta")
  if [[ "$sha" != "$GIT_SHA" || "$pr" != "${PR_NUMBER:-}" ]]; then
    rm -f "environments/${ws}.tfplan"
    return 1
  fi
}

delete_plan() {
  s3 delete-object --bucket "$LOCK_BUCKET" --key "$PLAN_KEY" >/dev/null 2>&1 || true
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
  local title="Terraform plan (\`${ws}\`)"
  local log show
  run_lock acquire || fail_lock_status "$ws" "$LOCK_RC" "$title"
  acquired=1
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init || ! run_tf "$log" -e "$ws" plan; then
    write_err "$title" "$(cat "$log")"
    exit 1
  fi
  show=$(mktemp)
  if ! "$EXECUTABLE" show -no-color "environments/${ws}.tfplan" >"$show" 2>&1; then
    write_err "$title" "$(cat "$show")"
    exit 1
  fi
  if ! upload_plan "$ws"; then
    write_err "$title" "The plan could not be saved to the state bucket. The lock is released. Please run \`/tf plan\` again."
    exit 1
  fi
  keep_lock=1
  comment_log "$title" "$(printf 'Commit `%s`. Run `/tf apply` to apply exactly this plan.' "$(short_sha "$GIT_SHA")")" "$show"
}

do_apply() {
  local ws=$1
  local title="Terraform apply (\`${ws}\`)"
  local log
  run_lock begin-apply || fail_lock_status "$ws" "$LOCK_RC" "$title"
  acquired=1
  keep_lock=1
  if ! download_plan "$ws"; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "$title" "$(printf 'No saved plan for commit `%s` in workspace `%s`. Run `/tf plan` first.\n' "$(short_sha "$GIT_SHA")" "$ws")"
    exit 1
  fi
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init || ! run_tf "$log" -e "$ws" apply; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "$title" "$(cat "$log")"
    exit 1
  fi
  bash "$SCRIPT_DIR/lock.sh" finish-apply
  acquired=0
  delete_plan
  comment_log "$title" "$(printf 'Plan for commit `%s` was applied.' "$(short_sha "$GIT_SHA")")" "$log"
}

do_unlock() {
  local ws=$1
  run_lock unlock || fail_lock_status "$ws" "$LOCK_RC" "Terraform unlock (\`${ws}\`)"
  delete_plan
  write_ok "Terraform unlock (\`${ws}\`)" "$(printf 'The lock for workspace `%s` is released. The saved plan can no longer be applied.' "$ws")"
}

# Pull request closed: release a lock held by this pull request.
do_release() {
  local ws=$1
  if run_lock unlock-idle; then
    delete_plan
    write_ok "Terraform unlock (\`${ws}\`)" "$(printf 'The pull request was closed. The lock for workspace `%s` is released.' "$ws")"
    return 0
  fi
  case "$LOCK_RC" in
    2 | 4) echo "No lock of this pull request on ${ws}." ;;
    3)
      write_err "Terraform unlock (\`${ws}\`)" "$(printf 'The pull request was closed while an apply was running. The lock for workspace `%s` stays. Release it with `/tf unlock` once the apply has finished.' "$ws")"
      exit 1
      ;;
    *)
      write_err "Terraform unlock (\`${ws}\`)" "The workspace lock could not be checked."
      exit 1
      ;;
  esac
}

delete_workspace() {
  local ws=$1
  (
    unset TF_WORKSPACE
    "$EXECUTABLE" workspace select default >/dev/null \
      && "$EXECUTABLE" workspace delete "$ws"
  ) || echo "Workspace ${ws} could not be deleted. Its state is empty and can stay." >&2
}

# Pull request of a preview closed: destroy the preview.
do_destroy() {
  local ws=$1
  local title="Terraform destroy (\`${ws}\`)"
  local log
  # A lock of this pull request or of a push to its branch belongs to the preview.
  bash "$SCRIPT_DIR/lock.sh" unlock-idle >/dev/null 2>&1 || true
  run_lock acquire || fail_lock_status "$ws" "$LOCK_RC" "$title"
  acquired=1
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init || ! run_tf "$log" -e "$ws" plan -destroy; then
    write_err "$title" "$(cat "$log")"
    exit 1
  fi
  run_lock begin-apply || fail_lock_status "$ws" "$LOCK_RC" "$title"
  keep_lock=1
  if ! run_tf "$log" -e "$ws" apply; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    write_err "$title" "$(cat "$log")"
    exit 1
  fi
  bash "$SCRIPT_DIR/lock.sh" finish-apply
  acquired=0
  delete_plan
  delete_workspace "$ws"
  comment_log "$title" "The pull request was closed. The preview was destroyed." "$log"
}

do_preview() {
  local ws=$1
  local log
  if ! run_lock acquire; then
    echo "Workspace ${ws} is locked. The push is not applied." >&2
    if [[ -f "$LOCK_STATE_FILE" ]]; then
      holder_text "$ws" >&2
    fi
    exit 1
  fi
  acquired=1
  write_secrets "$ws"
  log=$(mktemp)
  if ! run_tf "$log" -e "$ws" init || ! run_tf "$log" -e "$ws" plan; then
    exit 1
  fi
  run_lock begin-apply || exit 1
  keep_lock=1
  if ! run_tf "$log" -e "$ws" apply; then
    bash "$SCRIPT_DIR/lock.sh" abort-apply || true
    exit 1
  fi
  bash "$SCRIPT_DIR/lock.sh" finish-apply
  acquired=0
  echo "Preview ${ws} was applied ($(short_sha "$GIT_SHA"))."
}

ws=$(resolve_workspace)
echo "Workspace: ${ws}"

case "$COMMAND" in
  plan | apply | preview | destroy) ensure_env_files "$ws" ;;
esac

if [[ "$COMMAND" == "destroy" && "$ws" != preview-* ]]; then
  echo "destroy only runs for preview workspaces, not '${ws}'." >&2
  exit 1
fi

prepare_lock_env "$ws"

case "$COMMAND" in
  plan) do_plan "$ws" ;;
  apply) do_apply "$ws" ;;
  unlock) do_unlock "$ws" ;;
  release) do_release "$ws" ;;
  destroy) do_destroy "$ws" ;;
  preview) do_preview "$ws" ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
