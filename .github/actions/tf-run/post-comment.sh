#!/usr/bin/env bash
# Schreibt den vorbereiteten Kommentar, nachdem Plan-Artifact und Lauf feststehen.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER_TEMP=${RUNNER_TEMP:-/tmp}
OK_FILE="$RUNNER_TEMP/tf-comment-ok.md"
ERR_FILE="$RUNNER_TEMP/tf-comment-err.md"

if [[ -z "${PR_NUMBER:-}" ]]; then
  exit 0
fi

run_outcome=${RUN_OUTCOME:-failure}
upload_outcome=${UPLOAD_OUTCOME:-skipped}

if [[ "$run_outcome" == "success" && "$upload_outcome" != "failure" && -s "$OK_FILE" ]]; then
  bash "$SCRIPT_DIR/comment.sh" "$OK_FILE"
  exit 0
fi

if [[ "$upload_outcome" == "failure" ]]; then
  printf '### Terraform plan\n\nDer Plan ist gelaufen, das Artifact konnte nicht gespeichert werden. Bitte erneut `/tf plan` ausführen.\n' >"$ERR_FILE"
fi

if [[ ! -s "$ERR_FILE" && "$run_outcome" != "success" ]]; then
  printf '### Terraform\n\nDer Lauf ist vor Terraform fehlgeschlagen. Die Actions-Logs enthalten die Ursache.\n' >"$ERR_FILE"
fi

if [[ -s "$ERR_FILE" ]]; then
  bash "$SCRIPT_DIR/comment.sh" "$ERR_FILE"
fi
