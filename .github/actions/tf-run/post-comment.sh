#!/usr/bin/env bash
# Posts the prepared comment once the run outcome is known.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER_TEMP=${RUNNER_TEMP:-/tmp}
OK_FILE="$RUNNER_TEMP/tf-comment-ok.md"
ERR_FILE="$RUNNER_TEMP/tf-comment-err.md"

if [[ -z "${PR_NUMBER:-}" ]]; then
  exit 0
fi

run_outcome=${RUN_OUTCOME:-failure}

if [[ "$run_outcome" == "success" && -s "$OK_FILE" ]]; then
  bash "$SCRIPT_DIR/comment.sh" "$OK_FILE"
  exit 0
fi

if [[ ! -s "$ERR_FILE" && "$run_outcome" != "success" ]]; then
  printf '### Terraform\n\nThe run failed before Terraform started. The Actions logs contain the cause.\n' >"$ERR_FILE"
fi

if [[ -s "$ERR_FILE" ]]; then
  bash "$SCRIPT_DIR/comment.sh" "$ERR_FILE"
fi
