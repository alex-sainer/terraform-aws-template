# Developer tooling

What you need on your machine, what the configuration files at the repository root do, and how to run the checks that CI runs.

## Required

| Tool | Why | Install |
| ---- | --- | ------- |
| OpenTofu or Terraform `>= 1.10` | runs the configuration; `pipeline.json` says which one | `brew install opentofu` or `brew install hashicorp/tap/terraform` |
| `jq` | `scripts/tf` and `scripts/setup` read `pipeline.json` with it | `brew install jq` / `sudo apt-get install jq` |
| AWS CLI | credentials for the account; the pipeline scripts use `aws s3api` | `brew install awscli` |
| `git` | `scripts/tf` reads the branch | already present |

`.terraform-version` holds the exact release the pipeline installs (`1.10.5`). Version managers such as `tenv` or `tfenv` read the file too, so `tenv tofu install` or `tfenv install` gives you the same release locally.

## For contributing

Everything below is run by `pre-commit`, so you only need `pre-commit` itself plus the tools that the hooks cannot download:

```bash
brew install pre-commit shellcheck shfmt actionlint zizmor gitleaks
pre-commit install
pre-commit run --all-files
```

On Debian or Ubuntu, `pipx install pre-commit zizmor`, `apt-get install shellcheck`, and the release binaries of `shfmt`, `actionlint`, and `gitleaks`.

| Tool | What it checks | Hook downloads it |
| ---- | -------------- | ----------------- |
| `tofu fmt`, `tofu validate` | formatting and validity of the Terraform code | no, uses the tool on `PATH` |
| `tflint` with the AWS ruleset | Terraform best practices and AWS argument validation | yes, pinned in `.pre-commit-config.yaml` |
| `shellcheck` | shell errors and portability | yes (Python wheel) |
| `shfmt` | shell formatting, rules in `.editorconfig` | yes (Go module) |
| `gitleaks` | secrets in the commit | yes (Go module) |
| `actionlint` | GitHub workflow syntax, expressions, shellcheck inside `run:` | yes (Python wheel) |
| `zizmor` | GitHub workflow security: pins, permissions, injection | yes (Python wheel) |
| `scripts/pipeline-test.sh` | the branch-to-workspace mapping | n/a, needs `jq` |
| `scripts/lint-workflows.sh` | actionlint and zizmor over the templates and every rendered preview mode | n/a, needs `jq` and `rsync` |

`gh` (GitHub CLI) is optional locally. With `GH_TOKEN` set, zizmor checks action pins against GitHub instead of running offline.

## Configuration files

- `.pre-commit-config.yaml` — the hooks above, with pinned versions. `pre-commit autoupdate` bumps them.
- `.tflint.hcl` — enables the `terraform` preset and the AWS ruleset; `call_module_type = "local"` lints local modules under `modules/` too.
- `.editorconfig` — two-space indentation, LF, final newline. The `[[shell]]` section configures `shfmt`, including for scripts without an extension such as `scripts/tf`.
- `.shellcheckrc` — disables SC2016, because single quotes around `${{ ... }}` and Markdown backticks are intentional in the pipeline scripts.
- `.github/zizmor.yml` — disables one audit with a comment explaining why; see the file.
- `.terraform-version` — the tool release for CI and version managers.
- `.terraform.lock.hcl`, `bootstrap/.terraform.lock.hcl` — provider checksums for Linux and macOS, for the tool in `pipeline.json`.

## Running the checks

```bash
pre-commit run --all-files        # everything CI runs
bash scripts/pipeline-test.sh     # mapping tests only, fast
bash scripts/lint-workflows.sh    # workflow lint only
scripts/setup --render            # re-render generated files; must produce no diff on a clean checkout
```

`tofu validate` needs an initialized directory: `tofu init -backend=false` in the root and in `bootstrap/`. The pre-commit hook does that for you.

## Switching between Terraform and OpenTofu

`scripts/setup` changes `tool` in `pipeline.json`. The provider lock files hold one tool's registry only; after a switch, regenerate them:

```bash
rm .terraform.lock.hcl bootstrap/.terraform.lock.hcl
<tool> providers lock -platform=linux_amd64 -platform=darwin_arm64
<tool> -chdir=bootstrap providers lock -platform=linux_amd64 -platform=darwin_arm64
```

`scripts/setup` prints this reminder when the lock does not match the tool.
