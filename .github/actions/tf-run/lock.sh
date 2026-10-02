#!/usr/bin/env bash
# Sperre pro Workspace im State-Bucket: <state-key-dir>/pr-locks/<workspace>.json
# Befehle: acquire, begin-apply, finish-apply, abort-apply, release, unlock
set -euo pipefail

cmd=${1:?}

: "${LOCK_BUCKET:?}"
: "${LOCK_KEY:?}"
: "${LOCK_REGION:?}"
: "${LOCK_SHA:?}"
: "${LOCK_USER:?}"
: "${LOCK_REF:?}"

LOCK_PR=${LOCK_PR:-}
LOCK_ETAG_FILE=${LOCK_ETAG_FILE:-${RUNNER_TEMP:-/tmp}/tf-lock.etag}
LOCK_STATE_FILE=${LOCK_STATE_FILE:-${RUNNER_TEMP:-/tmp}/tf-lock.json}
mkdir -p "$(dirname "$LOCK_ETAG_FILE")" "$(dirname "$LOCK_STATE_FILE")"

aws_s3() {
  aws s3api "$@" --region "$LOCK_REGION"
}

normalize_etag() {
  local etag=$1
  etag=${etag#\"}
  etag=${etag%\"}
  printf '"%s"' "$etag"
}

write_body() {
  local applying=$1
  local dest=$2
  jq -n \
    --arg sha "$LOCK_SHA" \
    --arg user "$LOCK_USER" \
    --arg ref "$LOCK_REF" \
    --arg locked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson applying "$applying" \
    --arg pr "$LOCK_PR" \
    'if $pr == "" then
       {pr: null, sha: $sha, user: $user, locked_at: $locked_at, ref: $ref, applying: $applying}
     else
       {pr: ($pr | tonumber), sha: $sha, user: $user, locked_at: $locked_at, ref: $ref, applying: $applying}
     end' >"$dest"
}

read_lock() {
  local dest=$1
  local meta=$2
  if ! aws_s3 head-object --bucket "$LOCK_BUCKET" --key "$LOCK_KEY" >"$meta" 2>"$meta.err"; then
    if grep -q -E 'Not Found|404|NoSuchKey' "$meta.err"; then
      rm -f "$dest"
      return 1
    fi
    cat "$meta.err" >&2
    return 2
  fi
  aws_s3 get-object --bucket "$LOCK_BUCKET" --key "$LOCK_KEY" "$dest" >/dev/null
  cp "$dest" "$LOCK_STATE_FILE"
}

current_etag() {
  local meta=$1
  normalize_etag "$(jq -r '.ETag' "$meta")"
}

same_owner() {
  local file=$1
  local pr ref
  pr=$(jq -r '.pr // empty' "$file")
  ref=$(jq -r '.ref // empty' "$file")
  if [[ -n "$LOCK_PR" ]]; then
    [[ "$pr" == "$LOCK_PR" ]]
  else
    [[ -z "$pr" && "$ref" == "$LOCK_REF" ]]
  fi
}

can_unlock() {
  local file=$1
  local pr ref
  if same_owner "$file"; then
    return 0
  fi
  pr=$(jq -r '.pr // empty' "$file")
  ref=$(jq -r '.ref // empty' "$file")
  # Ein Preview-PR darf die Sperre eines Pushes auf demselben Branch lösen.
  [[ -n "$LOCK_PR" && -z "$pr" && "$ref" == "$LOCK_REF" ]]
}

put_new() {
  local body=$1
  local err
  err=$(mktemp)
  if aws_s3 put-object \
    --bucket "$LOCK_BUCKET" \
    --key "$LOCK_KEY" \
    --body "$body" \
    --content-type application/json \
    --if-none-match '*' \
    --query ETag --output text >"$LOCK_ETAG_FILE" 2>"$err"; then
    printf '%s' "$(normalize_etag "$(tr -d '[:space:]' <"$LOCK_ETAG_FILE")")" >"$LOCK_ETAG_FILE"
    rm -f "$err"
    return 0
  fi
  if grep -q -E 'PreconditionFailed|412|At least one of the pre-conditions' "$err"; then
    rm -f "$err"
    return 1
  fi
  cat "$err" >&2
  rm -f "$err"
  return 2
}

put_match() {
  local body=$1
  local etag=$2
  local err
  err=$(mktemp)
  set +e
  aws_s3 put-object \
    --bucket "$LOCK_BUCKET" \
    --key "$LOCK_KEY" \
    --body "$body" \
    --content-type application/json \
    --if-match "$etag" \
    --query ETag --output text >"$LOCK_ETAG_FILE" 2>"$err"
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s' "$(normalize_etag "$(cat "$LOCK_ETAG_FILE")")" >"$LOCK_ETAG_FILE"
    rm -f "$err"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  return "$status"
}

delete_match() {
  local etag=$1
  local err
  err=$(mktemp)
  set +e
  aws_s3 delete-object \
    --bucket "$LOCK_BUCKET" \
    --key "$LOCK_KEY" \
    --if-match "$etag" >"$err" 2>&1
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    rm -f "$err" "$LOCK_ETAG_FILE"
    return 0
  fi
  if grep -q -E 'Unknown options|Unknown option' "$err"; then
    local state meta now
    state=$(mktemp)
    meta=$(mktemp)
    rm -f "$err"
    if ! read_lock "$state" "$meta"; then
      rm -f "$state" "$meta" "$LOCK_ETAG_FILE"
      return 0
    fi
    now=$(current_etag "$meta")
    rm -f "$state" "$meta"
    if [[ "$now" != "$etag" ]]; then
      echo "Die Sperre wurde inzwischen geändert und bleibt bestehen." >&2
      return 1
    fi
    aws_s3 delete-object --bucket "$LOCK_BUCKET" --key "$LOCK_KEY" >/dev/null
    rm -f "$LOCK_ETAG_FILE"
    return 0
  fi
  if grep -q -E 'PreconditionFailed|412' "$err"; then
    echo "Die Sperre wurde inzwischen geändert und bleibt bestehen." >&2
    rm -f "$err"
    return 1
  fi
  cat "$err" >&2
  rm -f "$err"
  return "$status"
}

holder_message() {
  local file=$1
  cp "$file" "$LOCK_STATE_FILE"
}

case "$cmd" in
  acquire)
    body=$(mktemp)
    state=$(mktemp)
    meta=$(mktemp)
    write_body false "$body"
    if put_new "$body"; then
      put_status=0
    else
      put_status=$?
    fi
    if [[ $put_status -eq 0 ]]; then
      rm -f "$body" "$state" "$meta"
      exit 0
    fi
    if [[ $put_status -ne 1 ]]; then
      rm -f "$body" "$state" "$meta"
      exit 1
    fi
    set +e
    read_lock "$state" "$meta"
    read_status=$?
    set -e
    if [[ $read_status -ne 0 ]]; then
      echo "Sperre konnte nicht gelesen werden." >&2
      exit 1
    fi
    applying=$(jq -r '.applying // false' "$state")
    etag=$(current_etag "$meta")
    if same_owner "$state"; then
      if [[ "$applying" == "true" ]]; then
        holder_message "$state"
        echo "Für diesen Workspace läuft bereits ein Apply." >&2
        exit 3
      fi
      write_body false "$body"
      put_match "$body" "$etag"
      rm -f "$body" "$state" "$meta"
      exit 0
    fi
    holder_message "$state"
    rm -f "$body" "$state" "$meta"
    exit 2
    ;;
  begin-apply)
    state=$(mktemp)
    meta=$(mktemp)
    set +e
    read_lock "$state" "$meta"
    read_status=$?
    set -e
    if [[ $read_status -eq 1 ]]; then
      echo "Keine Sperre. Zuerst /tf plan ausführen." >&2
      exit 4
    fi
    if [[ $read_status -ne 0 ]]; then
      exit 1
    fi
    etag=$(current_etag "$meta")
    lock_sha=$(jq -r '.sha' "$state")
    if ! same_owner "$state"; then
      holder_message "$state"
      rm -f "$state" "$meta"
      exit 2
    fi
    if [[ "$lock_sha" != "$LOCK_SHA" ]]; then
      holder_message "$state"
      echo "Commit der Sperre ist $lock_sha, erwartet $LOCK_SHA." >&2
      rm -f "$state" "$meta"
      exit 5
    fi
    body=$(mktemp)
    write_body true "$body"
    put_match "$body" "$etag"
    rm -f "$body" "$state" "$meta"
    ;;
  finish-apply | release)
    if [[ ! -s "$LOCK_ETAG_FILE" ]]; then
      echo "ETag der Sperre fehlt." >&2
      exit 1
    fi
    etag=$(tr -d '[:space:]' <"$LOCK_ETAG_FILE")
    delete_match "$etag"
    ;;
  abort-apply)
    state=$(mktemp)
    meta=$(mktemp)
    body=$(mktemp)
    if ! read_lock "$state" "$meta"; then
      exit 0
    fi
    if ! same_owner "$state"; then
      rm -f "$state" "$meta" "$body"
      exit 0
    fi
    etag=$(current_etag "$meta")
    # SHA der bestehenden Sperre behalten, nur applying zurücksetzen.
    LOCK_SHA=$(jq -r '.sha' "$state")
    LOCK_USER=$(jq -r '.user' "$state")
    LOCK_REF=$(jq -r '.ref' "$state")
    saved_pr=$(jq -r '.pr // empty' "$state")
    LOCK_PR=$saved_pr
    write_body false "$body"
    put_match "$body" "$etag"
    rm -f "$state" "$meta" "$body"
    ;;
  unlock)
    state=$(mktemp)
    meta=$(mktemp)
    set +e
    read_lock "$state" "$meta"
    read_status=$?
    set -e
    if [[ $read_status -eq 1 ]]; then
      echo "Für diesen Workspace liegt keine Sperre." >&2
      exit 4
    fi
    if [[ $read_status -ne 0 ]]; then
      exit 1
    fi
    if ! can_unlock "$state"; then
      holder_message "$state"
      rm -f "$state" "$meta"
      exit 2
    fi
    etag=$(current_etag "$meta")
    printf '%s' "$etag" >"$LOCK_ETAG_FILE"
    delete_match "$etag"
    rm -f "$state" "$meta"
    ;;
  *)
    echo "Unbekannter Befehl: $cmd" >&2
    exit 2
    ;;
esac
