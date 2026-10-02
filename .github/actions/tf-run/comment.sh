#!/usr/bin/env bash
# Schreibt eine Datei als Kommentar in den Pull Request.
# Aufruf: comment.sh <datei>
set -euo pipefail

file=${1:?}
if [[ -z "${PR_NUMBER:-}" || ! -s "$file" ]]; then
  exit 0
fi
if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GH_TOKEN oder GITHUB_REPOSITORY fehlt, Kommentar wird nicht geschrieben." >&2
  exit 1
fi

jq -n --rawfile body "$file" '{body: $body}' \
  | gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --input - >/dev/null
