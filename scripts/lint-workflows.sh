#!/usr/bin/env bash
# Lints the GitHub workflows with actionlint and zizmor: the active .yml files, the
# .yml.template files, and the workflows scripts/setup renders for every preview mode.
# zizmor only reads files that end in .yml, so templates and renders are linted as copies.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

for cmd in actionlint zizmor jq rsync; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is missing. See docs/tooling.md." >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out="$tmp/workflows"
copy="$tmp/repo"
mkdir -p "$out"

for f in .github/workflows/*.yml.template; do
  cp "$f" "$out/template-$(basename "$f" .template)"
done

for mode in off prefix suffix label; do
  rm -rf "$copy"
  rsync -a --exclude .git --exclude .terraform "$ROOT/" "$copy/"
  git -C "$copy" init -q
  jq --arg mode "$mode" '.preview.mode = $mode' "$copy/pipeline.json" >"$tmp/pipeline.json"
  mv "$tmp/pipeline.json" "$copy/pipeline.json"
  if ! (cd "$copy" && ACTIONS_ENABLED=true NO_COLOR=1 bash scripts/setup --render >"$tmp/setup.log" 2>&1); then
    cat "$tmp/setup.log" >&2
    echo "scripts/setup --render failed for preview mode $mode." >&2
    exit 1
  fi
  for f in "$copy"/.github/workflows/*.yml; do
    cp "$f" "$out/$mode-$(basename "$f")"
  done
done

# Copies first: the active list can be empty, and bash 3.2 rejects empty arrays under set -u.
shopt -s nullglob
files=("$out"/*.yml .github/workflows/*.yml .github/workflows/*.yaml)
actions=(.github/actions/*/action.yml)
shopt -u nullglob

echo "Copies in $out: template-* are the .yml.template files, <mode>-* come from scripts/setup --render."

status=0
actionlint "${files[@]}" || status=1

zizmor_args=(--config .github/zizmor.yml)
if [[ -z "${GH_TOKEN:-}" ]]; then
  zizmor_args+=(--offline)
fi
zizmor "${zizmor_args[@]}" "${files[@]}" "${actions[@]}" || status=1

exit "$status"
