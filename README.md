# Terraform AWS Template

Starting point for an AWS project with Terraform or OpenTofu. You create your own repository from it, replace the placeholders, and add your resources. A private example bucket shows how a resource, variables, and tags fit together.

## What this is

This template uses a branch-based approach. The Git branch is the environment.

One codebase describes every environment. Each environment is its own Terraform workspace with its own state, for example `prod`, and as many `preview-<name>` workspaces as you need. State lives in one shared S3 bucket. The workspace separates it, for example `env:/prod/...`.

The shipped [`pipeline.json`](pipeline.json) uses OpenTofu and maps one branch:

| Branch | Workspace |
| ------ | --------- |
| `main` | `prod`    |

Preview environments are off. `scripts/setup` adds stages such as `develop` → `dev`, switches previews on, or changes the tool.

`scripts/tf` reads the checked-out branch and `pipeline.json`, then selects the workspace, the variable file, and the backend.

Every environment file is present on every branch. Locally, the checked-out branch selects which files are used. In a pull request, the target branch selects them, unless the head is a preview: then that preview applies. The pipeline that does this in GitHub is in [docs/pipeline.md](docs/pipeline.md).

## Why

The branch is already the path a change takes. Binding the environment to that branch keeps the promotion path and the state target aligned.

With more stages, work moves by merge, for example from `develop` to `main`. Each of those branches is one environment, and the configuration stays a single tree. `scripts/tf` reads the branch, so plan and apply use the state that belongs to the branch you are on.

A preview follows the same rule for a short-lived environment. The branch or pull request gets its own workspace, and the long-lived stages stay on their own branches. Preview modes are a branch prefix (`preview/<name>`), a branch suffix (`feature/foo-preview`), or a label on the pull request.

Locally and in GitHub the command is `scripts/tf`. The pipeline sits on top of this mapping. Its setup, including OIDC and permissions, is separate: [docs/pipeline.md](docs/pipeline.md).

## Setup

These steps get an environment running on your machine.

### 1. Create your repository

Create a new repository from this template, or clone it. With the shipped `pipeline.json`, `main` is prod. Work on feature branches and merge them into `main`.

### 2. Choose stages, branches, and Terraform or OpenTofu

Install `jq`. `scripts/tf` and `scripts/setup` read `pipeline.json` with it. If it is missing, they stop and print how to install it (`brew install jq` on macOS, `sudo apt-get install jq` on Debian or Ubuntu).

Install OpenTofu or Terraform `>= 1.10`, and set up AWS credentials for the target account.

`pipeline.json` at the repository root is the mapping for local runs and for GitHub Actions. `tool` is `terraform` or `tofu`. Each entry under `environments` is a stage: workspace name, git branch, and whether apply needs approval in the GitHub environment of the same name. `preview.mode` is `prefix`, `suffix`, `label`, or `off`.

```bash
scripts/setup
```

The script walks through four steps with arrow-key menus: the tool (it shows whether Terraform or OpenTofu is installed), the environments (the production environment and its branch, then keep, edit, or remove each existing one, and add more), preview environments (whether to enable them, then branch prefix, branch suffix, or pull request label, and the concrete value), and GitHub Actions. Invalid input is reported right at the prompt. Before writing, it shows a summary and the list of files it will create, update, or remove, and asks for confirmation. Ctrl+C aborts without changing anything.

On confirmation it writes `pipeline.json`, adds missing `environments/<name>.tfvars` and backend files (and the shared `environments/preview.*` files when previews are on), and rewrites the preview workflow trigger. When GitHub Actions are enabled, it writes `.github/workflows/terraform-commands.yml`, `.github/workflows/terraform-cleanup.yml` and, if preview is on, `.github/workflows/terraform-preview.yml`. It ends with the next steps: the IAM roles and OIDC subjects, the GitHub environments, and the secret names.

`scripts/setup --render` rewrites the preview trigger from the current file without questions, and refreshes those workflow files when they are already active. `scripts/setup --help` lists the options. Set `NO_COLOR=1` for plain output.

`EXECUTABLE` overrides `tool` for one call. If it is unset, `scripts/tf` uses `pipeline.json`.

```bash
EXECUTABLE=terraform scripts/tf plan
```

`scripts/pipeline-test.sh` tests the branch mapping with its own fixtures, without AWS.

### 3. Set up the state bucket

The state bucket has its own configuration in [`bootstrap/`](bootstrap/main.tf), with local state. Create it once:

```bash
tofu -chdir=bootstrap init
tofu -chdir=bootstrap apply -var state_bucket_name=acme-shop-tfstate -var aws_region=eu-central-1
```

The bucket gets versioning, encryption, a public access block, a TLS-only policy, and `prevent_destroy`. The local state in `bootstrap/` is not committed. Keep it if you want to change the bucket later, or import the bucket again when needed.

Then replace every `REPLACE_ME` in `environments/*.tfvars` and `environments/*.backend.tfvars`. `bucket` in every backend file is the state bucket. `name_prefix` in the tfvars is a globally unique prefix for resource names; the environment is appended, so the example bucket in `prod` is `<name_prefix>-prod-example`. Until `name_prefix` is replaced, plan stops with a validation error.

### 4. Init, plan, and apply

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
```

`plan` writes `environments/<env>.tfplan`. `apply` applies only that file and deletes it afterwards. If no plan file is present, `apply` stops.

The same commands work for another environment than the checked-out branch. `-e` and `--env` are equivalent and come before the subcommand. If the name differs from the branch, the script writes a note to stderr and continues.

```bash
scripts/tf -e prod plan
scripts/tf --env prod apply
```

Further commands, including `import`, destroy, and secret var-files, are under [Commands](#commands).

## On a branch

Your own resources go in as further `.tf` files next to [`example-s3-bucket.tf`](example-s3-bucket.tf). New variables go into `_variables.tf` and into `environments/<env>.tfvars`. Build resource names from `name_prefix` and `local.environment`, so that every environment and every preview gets its own names.

Once the [pipeline](docs/pipeline.md) is in place, a pull request runs the same plan and apply from a comment.

## Commands

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
scripts/tf plan -destroy   # then scripts/tf apply
scripts/tf import aws_s3_bucket.example my-bucket
```

```bash
scripts/tf -e prod plan
scripts/tf --env prod apply
scripts/tf --env preview-feature123 init
```

Arguments after `plan` go to Terraform, for example `-destroy` or `-target`.

`environments/<env>.secrets.tfvars` is passed in automatically once the file exists. It is gitignored. A template lives at `environments/secrets.tfvars.example`. In the pipeline, the repository secret `TF_SECRETS_TFVARS_<ENV>` (for example `TF_SECRETS_TFVARS_PROD`) writes this file when it is set. See [docs/pipeline.md](docs/pipeline.md).

## Files

- `_terraform.tf` — Terraform version, provider, S3 backend
- `_providers.tf` — all providers for the project are defined here
- `_variables.tf` — variables
- `_locals.tf` — shared locals and tags
- `_outputs.tf` — outputs
- `example-s3-bucket.tf` — private example bucket
- `bootstrap/` — one-time setup of the state bucket, with local state
- `environments/<env>.tfvars` — variables for the environment
- `environments/<env>.backend.tfvars` — backend configuration
- `environments/preview.tfvars`, `environments/preview.backend.tfvars` — shared by all previews
- `environments/<env>.secrets.tfvars` — optional secrets, not in Git
- `environments/<env>.tfplan` — plan file, not in Git
- `pipeline.json` — tool, stages, branch mapping, and preview mode, for local runs and GitHub Actions
- `scripts/setup` — writes `pipeline.json`, env files, and the workflows
- `scripts/pipeline-test.sh` — tests for the branch mapping
- `.github/workflows/terraform-commands.yml.template` — comment workflow
- `.github/workflows/terraform-cleanup.yml.template` — releases locks and destroys previews when a pull request closes
- `.github/workflows/terraform-preview.yml.template` — preview workflow, written when preview is on
- `.github/actions/tf-run/` — shared steps for OIDC, the lock, and `scripts/tf`

`.terraform.lock.hcl` and `bootstrap/.terraform.lock.hcl` pin the AWS provider for the tool in `pipeline.json` (OpenTofu, `registry.opentofu.org`) on Linux and macOS. Both tools drop the other tool's entry on `init`, so the lock holds one tool only. After a tool switch or a provider upgrade, delete the lock files, run `<tool> providers lock -platform=linux_amd64 -platform=darwin_arm64` in the root and in `bootstrap/`, and commit them. `scripts/setup` reminds you when the lock does not match the tool.

`bucket`, `key`, and `region` live in the backend tfvars. The state key is the same for every environment (`terraform-aws-template/terraform.tfstate`). The workspace does the separation, for example `env:/prod/terraform-aws-template/terraform.tfstate`.

## Preview environment

Turn previews on with `scripts/setup`. With the prefix mode:

```bash
git checkout -b preview/feature123
scripts/tf init
scripts/tf plan
scripts/tf apply
```

All previews share `environments/preview.tfvars` and `environments/preview.backend.tfvars`, so a new preview needs no new files. Because resource names contain the workspace, previews do not collide. A preview that needs its own values can add `environments/preview-<name>.tfvars` or `.backend.tfvars`; those win over the shared files.

A suffix `feature/foo-preview` becomes the workspace `preview-feature--foo`: each `/` becomes `--`. Branch path segments must not be empty, start or end with `-`, or contain `--`, so two branches never map to the same workspace. A label on a pull request does not select a workspace locally; use `-e` or `--env`.

In GitHub, a preview is destroyed when its pull request closes. A preview without a pull request is destroyed by hand:

```bash
scripts/tf -e preview-feature123 plan -destroy
scripts/tf -e preview-feature123 apply
```

## License

This template is released under the MIT License. The copyright notice and the license text are in [LICENSE.md](LICENSE.md).
