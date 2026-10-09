#!/usr/bin/env bash
# Posts a file as a comment on the pull request.
# Usage: comment.sh <file>
set -euo pipefail

file=${1:?}
if [[ -z "${PR_NUMBER:-}" || ! -s "$file" ]]; then
  exit 0
fi
if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GH_TOKEN or GITHUB_REPOSITORY is missing, the comment is not posted." >&2
  exit 1
fi

jq -n --rawfile body "$file" '{body: $body}' \
  | gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --input - >/dev/null
