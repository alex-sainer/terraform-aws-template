#!/usr/bin/env bash
# Prüft die Auflösung aus pipeline.json ohne Terraform und ohne AWS.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PIPE="$ROOT/scripts/pipeline.sh"
fail=0

assert_eq() {
  local got=$1
  local want=$2
  local label=$3
  if [[ "$got" != "$want" ]]; then
    echo "FAIL $label: got '$got' want '$want'" >&2
    fail=1
  fi
}

assert_ok() {
  local label=$1
  shift
  if ! "$@" >/dev/null; then
    echo "FAIL $label: expected success" >&2
    fail=1
  fi
}

assert_fail() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL $label: expected failure" >&2
    fail=1
  fi
}

export PIPELINE_CONFIG="$ROOT/pipeline.json"
unset PIPELINE_LABELS || true

assert_eq "$(bash "$PIPE" tool)" "terraform" "tool"
assert_eq "$(bash "$PIPE" workspace develop)" "dev" "develop"
assert_eq "$(bash "$PIPE" workspace staging)" "staging" "staging"
assert_eq "$(bash "$PIPE" workspace main)" "prod" "main"
assert_eq "$(bash "$PIPE" protected prod)" "true" "prod protected"
assert_eq "$(bash "$PIPE" protected staging)" "true" "staging protected"
assert_eq "$(bash "$PIPE" protected dev)" "false" "dev protected"
assert_eq "$(bash "$PIPE" protected preview-feature123)" "false" "preview unprotected"
assert_eq "$(bash "$PIPE" workspace-pr feature/foo develop)" "dev" "pr base develop"
assert_eq "$(bash "$PIPE" workspace-pr preview/feature123 develop)" "preview-feature123" "prefix wins"
assert_eq "$(bash "$PIPE" workspace preview/ticket-769)" "preview-ticket-769" "prefix local"
assert_ok "validate preview" bash "$PIPE" validate preview-feature123
assert_ok "validate dev" bash "$PIPE" validate dev
assert_ok "check default" bash "$PIPE" check
assert_fail "unknown branch" bash "$PIPE" workspace feature/foo
assert_fail "nested preview" bash "$PIPE" workspace preview/a/b
assert_fail "default env" bash "$PIPE" validate default
assert_fail "unknown env" bash "$PIPE" validate qa

tmp=$(mktemp)
cat >"$tmp" <<'EOF'
{
  "tool": "tofu",
  "environments": [
    {"name": "dev", "branch": "develop", "protected": false},
    {"name": "prod", "branch": "main", "protected": true}
  ],
  "preview": {
    "mode": "suffix",
    "prefix": "preview/",
    "suffix": "-preview",
    "label": "preview"
  }
}
EOF
export PIPELINE_CONFIG="$tmp"
assert_eq "$(bash "$PIPE" tool)" "tofu" "suffix tool"
assert_eq "$(bash "$PIPE" workspace feature/foo-preview)" "preview-feature-foo" "suffix nested"
assert_eq "$(bash "$PIPE" workspace foo-preview)" "preview-foo" "suffix plain"
assert_eq "$(bash "$PIPE" workspace-pr feature/foo-preview main)" "preview-feature-foo" "suffix wins"
assert_eq "$(bash "$PIPE" workspace develop)" "dev" "suffix leaves develop"
assert_fail "suffix unknown" bash "$PIPE" workspace feature/foo

cat >"$tmp" <<'EOF'
{
  "tool": "terraform",
  "environments": [
    {"name": "dev", "branch": "develop", "protected": false},
    {"name": "prod", "branch": "main", "protected": true}
  ],
  "preview": {
    "mode": "label",
    "prefix": "preview/",
    "suffix": "-preview",
    "label": "preview"
  }
}
EOF
export PIPELINE_LABELS='["preview"]'
assert_eq "$(bash "$PIPE" workspace-pr feature/foo develop)" "preview-feature-foo" "label set"
export PIPELINE_LABELS='["other"]'
assert_eq "$(bash "$PIPE" workspace-pr feature/foo develop)" "dev" "label absent"
unset PIPELINE_LABELS
assert_fail "label local branch" bash "$PIPE" workspace feature/foo
assert_eq "$(bash "$PIPE" preview-workspace feature/foo)" "preview-feature-foo" "label preview command"

cat >"$tmp" <<'EOF'
{
  "tool": "terraform",
  "environments": [
    {"name": "dev", "branch": "preview/dev", "protected": false}
  ],
  "preview": {
    "mode": "prefix",
    "prefix": "preview/",
    "suffix": "-preview",
    "label": "preview"
  }
}
EOF
assert_fail "preview conflicts with stage" bash "$PIPE" check

cat >"$tmp" <<'EOF'
{
  "tool": "terraform",
  "environments": [
    {"name": "dev", "branch": "develop", "protected": false}
  ],
  "preview": {
    "mode": "off",
    "prefix": "preview/",
    "suffix": "-preview",
    "label": "preview"
  }
}
EOF
unset PIPELINE_LABELS || true
assert_eq "$(bash "$PIPE" workspace-pr preview/feature123 develop)" "dev" "preview off"
assert_fail "preview off validate" bash "$PIPE" validate preview-feature123

rm -f "$tmp"

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "ok"
