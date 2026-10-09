#!/usr/bin/env bash
# Prints the workspace for a pull request.
# Argument 1: head branch. Argument 2: target branch.
# Labels come from PIPELINE_LABELS (JSON array). A preview wins over the target branch.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: workspace.sh <head-ref> <base-ref>" >&2
  exit 2
fi

ROOT=${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}
exec bash "$ROOT/scripts/pipeline.sh" workspace-pr "$1" "$2"
