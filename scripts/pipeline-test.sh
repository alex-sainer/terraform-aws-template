#!/usr/bin/env bash
# Tests the resolution from pipeline.json without Terraform and without AWS.
# Uses its own fixtures, so the repository's pipeline.json can change freely.
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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PIPELINE_CONFIG="$tmp/pipeline.json"
unset PIPELINE_LABELS || true

fixture() {
  local mode=$1
  local tool=${2:-terraform}
  cat >"$PIPELINE_CONFIG" <<EOF
{
  "tool": "$tool",
  "environments": [
    {"name": "dev", "branch": "develop", "protected": false},
    {"name": "staging", "branch": "staging", "protected": true},
    {"name": "prod", "branch": "main", "protected": true}
  ],
  "preview": {"mode": "$mode", "prefix": "preview/", "suffix": "-preview", "label": "preview"}
}
EOF
}

# The repository's own file must always pass the check.
PIPELINE_CONFIG="$ROOT/pipeline.json" assert_ok "repo pipeline.json" bash "$PIPE" check

# Prefix mode
fixture prefix
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
assert_ok "check prefix" bash "$PIPE" check
assert_fail "unknown branch" bash "$PIPE" workspace feature/foo
assert_fail "nested preview" bash "$PIPE" workspace preview/a/b
assert_fail "uppercase preview" bash "$PIPE" workspace preview/Feature123
assert_fail "underscore preview" bash "$PIPE" workspace preview/feature_123
assert_fail "default env" bash "$PIPE" validate default
assert_fail "unknown env" bash "$PIPE" validate qa
assert_fail "uppercase env" bash "$PIPE" validate Prod
assert_fail "underscore env" bash "$PIPE" validate preview-feature_1

# GitHub environment and secret name
assert_eq "$(bash "$PIPE" environment prod)" "prod" "environment stage"
assert_eq "$(bash "$PIPE" environment preview-feature123)" "preview" "environment preview"
assert_eq "$(bash "$PIPE" secret-name prod)" "TF_SECRETS_TFVARS_PROD" "secret stage"
assert_eq "$(bash "$PIPE" secret-name preview-x)" "TF_SECRETS_TFVARS_PREVIEW" "secret preview"

# Env files: previews fall back to the shared preview files
mkdir -p "$tmp/environments"
touch "$tmp/environments/preview.tfvars" "$tmp/environments/preview.backend.tfvars"
export PIPELINE_ROOT="$tmp"
assert_eq "$(bash "$PIPE" env-file preview-x tfvars)" "environments/preview.tfvars" "preview shared tfvars"
assert_eq "$(bash "$PIPE" env-file preview-x backend)" "environments/preview.backend.tfvars" "preview shared backend"
assert_eq "$(bash "$PIPE" env-file preview-x secrets)" "environments/preview-x.secrets.tfvars" "preview secrets without shared"
touch "$tmp/environments/preview-x.tfvars"
assert_eq "$(bash "$PIPE" env-file preview-x tfvars)" "environments/preview-x.tfvars" "preview own tfvars"
assert_eq "$(bash "$PIPE" env-file prod tfvars)" "environments/prod.tfvars" "stage tfvars"
assert_fail "env-file kind" bash "$PIPE" env-file prod plan
unset PIPELINE_ROOT

# Suffix mode
fixture suffix tofu
assert_eq "$(bash "$PIPE" tool)" "tofu" "suffix tool"
assert_eq "$(bash "$PIPE" workspace feature/foo-preview)" "preview-feature--foo" "suffix nested"
assert_eq "$(bash "$PIPE" workspace feature-foo-preview)" "preview-feature-foo" "suffix plain hyphen"
assert_eq "$(bash "$PIPE" workspace foo-preview)" "preview-foo" "suffix plain"
assert_eq "$(bash "$PIPE" workspace-pr feature/foo-preview main)" "preview-feature--foo" "suffix wins"
assert_eq "$(bash "$PIPE" workspace develop)" "dev" "suffix leaves develop"
assert_fail "suffix unknown" bash "$PIPE" workspace feature/foo
assert_fail "suffix empty segment" bash "$PIPE" workspace feature/-preview
assert_fail "suffix double hyphen" bash "$PIPE" workspace feature--foo-preview
assert_fail "suffix segment hyphen" bash "$PIPE" workspace a-/b-preview
assert_fail "suffix only" bash "$PIPE" workspace -preview
assert_fail "suffix uppercase" bash "$PIPE" workspace Feature/foo-preview
assert_fail "suffix underscore" bash "$PIPE" workspace feature_foo-preview

# Label mode
fixture label
export PIPELINE_LABELS='["preview"]'
assert_eq "$(bash "$PIPE" workspace-pr feature/foo develop)" "preview-feature--foo" "label set"
export PIPELINE_LABELS='["other"]'
assert_eq "$(bash "$PIPE" workspace-pr feature/foo develop)" "dev" "label absent"
unset PIPELINE_LABELS
assert_fail "label local branch" bash "$PIPE" workspace feature/foo
assert_eq "$(bash "$PIPE" preview-workspace feature/foo)" "preview-feature--foo" "label preview command"

# Off
fixture off
assert_eq "$(bash "$PIPE" workspace-pr preview/feature123 develop)" "dev" "preview off"
assert_fail "preview off validate" bash "$PIPE" validate preview-feature123

# Invalid configurations
cat >"$PIPELINE_CONFIG" <<'EOF'
{
  "tool": "terraform",
  "environments": [{"name": "dev", "branch": "preview/dev", "protected": false}],
  "preview": {"mode": "prefix", "prefix": "preview/", "suffix": "-preview", "label": "preview"}
}
EOF
assert_fail "preview conflicts with stage" bash "$PIPE" check

cat >"$PIPELINE_CONFIG" <<'EOF'
{
  "tool": "terraform",
  "environments": [{"name": "preview", "branch": "develop", "protected": false}],
  "preview": {"mode": "off", "prefix": "preview/", "suffix": "-preview", "label": "preview"}
}
EOF
assert_fail "stage named preview" bash "$PIPE" check

cat >"$PIPELINE_CONFIG" <<'EOF'
{
  "tool": "terraform",
  "environments": [{"name": "qa_1", "branch": "qa", "protected": false}],
  "preview": {"mode": "off", "prefix": "preview/", "suffix": "-preview", "label": "preview"}
}
EOF
assert_fail "underscore in stage name" bash "$PIPE" check

cat >"$PIPELINE_CONFIG" <<'EOF'
{
  "tool": "terraform",
  "environments": [{"name": "Staging", "branch": "staging", "protected": false}],
  "preview": {"mode": "off", "prefix": "preview/", "suffix": "-preview", "label": "preview"}
}
EOF
assert_fail "uppercase in stage name" bash "$PIPE" check

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "ok"
