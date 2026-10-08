#!/usr/bin/env bash
# Gibt den Workspace für einen Pull Request aus.
# Argument 1: Head-Branch. Argument 2: Zielbranch.
# Labels stehen in PIPELINE_LABELS (JSON-Array). Preview gewinnt vor dem Zielbranch.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Aufruf: workspace.sh <head-ref> <base-ref>" >&2
  exit 2
fi

ROOT=${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}
exec bash "$ROOT/scripts/pipeline.sh" workspace-pr "$1" "$2"
