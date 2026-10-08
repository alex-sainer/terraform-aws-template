#!/usr/bin/env bash
# Prüft einen Pull-Request-Kommentar und schreibt die Job-Outputs.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

trim() {
  local s=$1
  s=${s//$'\r'/}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

post() {
  local text=$1
  local file
  file=$(mktemp)
  printf '%s\n' "$text" >"$file"
  PR_NUMBER="${PR_NUMBER:-}" bash "$SCRIPT_DIR/comment.sh" "$file" || true
  rm -f "$file"
}

react() {
  gh api --method POST \
    "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}/reactions" \
    -f content="$1" >/dev/null || true
}

: "${COMMENT_BODY:?}"
: "${COMMENT_ID:?}"
: "${COMMENT_USER:?}"
: "${PR_NUMBER:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?}"
: "${GITHUB_OUTPUT:?}"

body=$(trim "$COMMENT_BODY")
case "$body" in
  "/tf plan" | "/tf apply" | "/tf unlock")
    command=${body#/tf }
    ;;
  *)
    exit 0
    ;;
esac

if [[ "${COMMENT_USER_TYPE:-}" == "Bot" ]]; then
  exit 0
fi

pr_json=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")
head_repo=$(jq -r '.head.repo.full_name // empty' <<<"$pr_json")
base_repo=$(jq -r '.base.repo.full_name' <<<"$pr_json")
head_ref=$(jq -r '.head.ref' <<<"$pr_json")
head_sha=$(jq -r '.head.sha' <<<"$pr_json")
base_ref=$(jq -r '.base.ref' <<<"$pr_json")

if [[ -z "$head_repo" || "$head_repo" != "$base_repo" ]]; then
  post "Forks sind ausgeschlossen. /tf plan, /tf apply und /tf unlock laufen nur für Branches dieses Repositories."
  react "-1"
  exit 1
fi

perm=$(gh api "repos/${GITHUB_REPOSITORY}/collaborators/${COMMENT_USER}/permission" --jq .permission)
case "$perm" in
  admin | write) ;;
  *)
    post "Nur Personen mit Schreibrecht können /tf plan, /tf apply und /tf unlock auslösen."
    react "-1"
    exit 1
    ;;
esac

ROOT=${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}
export PIPELINE_LABELS
PIPELINE_LABELS=$(jq -c '[(.labels // [])[].name]' <<<"$pr_json")

err_file=$(mktemp)
if ! ws=$(bash "$SCRIPT_DIR/workspace.sh" "$head_ref" "$base_ref" 2>"$err_file"); then
  post "$(cat "$err_file")"
  rm -f "$err_file"
  react "-1"
  exit 1
fi
rm -f "$err_file"
protected=$(bash "$ROOT/scripts/pipeline.sh" protected "$ws")

react "eyes"

{
  echo "command<<EOF"
  echo "$command"
  echo "EOF"
  echo "workspace<<EOF"
  echo "$ws"
  echo "EOF"
  echo "protected<<EOF"
  echo "$protected"
  echo "EOF"
  echo "head_sha<<EOF"
  echo "$head_sha"
  echo "EOF"
  echo "head_ref<<EOF"
  echo "$head_ref"
  echo "EOF"
  echo "base_ref<<EOF"
  echo "$base_ref"
  echo "EOF"
  echo "pr<<EOF"
  echo "$PR_NUMBER"
  echo "EOF"
} >>"$GITHUB_OUTPUT"
