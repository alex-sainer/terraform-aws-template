# Terraform AWS Template

Starting point for an AWS project with Terraform or OpenTofu. You create your own repository from it, replace the placeholders, and add your resources. A private example bucket shows how a resource, variables, and tags fit together.

## What this is

This template uses a branch-based approach. The Git branch is the environment.

One codebase describes every environment. Each environment is its own Terraform workspace with its own state: `dev`, `staging`, `prod`, and as many `preview-<name>` workspaces as you need. State lives in one shared S3 bucket. The workspace separates it, for example `env:/prod/...` and `env:/dev/...`.

The shipped [`pipeline.json`](pipeline.json) maps branches like this. `scripts/setup` rewrites that file.

| Branch           | Workspace        |
| ---------------- | ---------------- |
| `main`           | `prod`           |
| `develop`        | `dev`            |
| `staging`        | `staging`        |
| `preview/<name>` | `preview-<name>` |

`scripts/tf` reads the checked-out branch and `pipeline.json`, then selects the workspace, the variable file, and the backend. In the shipped prefix mode, only the first `/` becomes a hyphen. `preview/feature123` becomes `preview-feature123`, and `preview/ticket-769` becomes `preview-ticket-769`.

Every environment file is present on every branch. Locally, the checked-out branch selects which files are used. In a pull request, the target branch selects them, unless the head is a preview: then that preview applies. The pipeline that does this in GitHub is in [docs/pipeline.md](docs/pipeline.md).

## Why

The branch is already the path a change takes. Binding the environment to that branch keeps the promotion path and the state target aligned.

Work starts on `develop` and moves by merge to `staging`, then to `main`. Each of those branches is one environment, and the configuration stays a single tree. `scripts/tf` reads the branch, so plan and apply use the state that belongs to the branch you are on. Because every branch carries every environment file, a merge leaves that choice to the branch name.

A preview follows the same rule for a short-lived environment. The branch or pull request gets its own workspace, and the long-lived stages stay on their own branches. The shipped preview mode is a branch prefix, `preview/<name>`. `scripts/setup` can switch that to a branch suffix (`feature/foo-preview`), a label on the pull request, or off.

Locally and in GitHub the command is `scripts/tf`. The pipeline sits on top of this mapping. Its setup, including OIDC and permissions, is separate: [docs/pipeline.md](docs/pipeline.md).

## Setup

These steps get an environment running from a branch on your machine.

### 1. Create your repository

Create a new repository from this template, or clone it. For day-to-day work, check out `develop`. With the shipped `pipeline.json`, `main` is prod and `staging` is staging.

### 2. Choose stages, branches, and Terraform or OpenTofu

Install `jq`. `scripts/tf` and `scripts/setup` read `pipeline.json` with it. If it is missing, they stop and print how to install it (`brew install jq` on macOS, `sudo apt-get install jq` on Debian or Ubuntu).

Install Terraform `>= 1.10` or OpenTofu, and set up AWS credentials for the target account.

`pipeline.json` at the repository root is the mapping for local runs and for GitHub Actions. `tool` is `terraform` or `tofu`. Each entry under `environments` is a stage: workspace name, git branch, and whether apply waits for a GitHub environment of the same name. `preview.mode` is `prefix`, `suffix`, `label`, or `off`.

```bash
scripts/setup
```

The script starts with a short introduction, then asks which tool to use, what the production environment is called and which branch tracks it, whether to add further environment branches, whether to enable preview environments and in which form, and whether to enable GitHub Actions. It then writes `pipeline.json`. It adds missing `environments/<name>.tfvars` and backend files, and rewrites the preview workflow trigger. When GitHub Actions are enabled, it writes `.github/workflows/terraform-commands.yml` and, if preview is on, `.github/workflows/terraform-preview.yml`. `scripts/setup --render` rewrites the preview trigger from the current file without questions, and refreshes those workflow files when they are already active.

`EXECUTABLE` overrides `tool` for one call. If it is unset, `scripts/tf` uses `pipeline.json`.

```bash
EXECUTABLE=tofu scripts/tf plan
```

### 3. Set up the state bucket

In `environments/<env>.tfvars` and `environments/<env>.backend.tfvars`, replace every name that starts with `REPLACE_ME`. The state bucket name is the same in every backend file and in the TODO block of `_terraform.tf`.

The state bucket resource is commented out in `_terraform.tf`, with the placeholder `REPLACE_ME-tfstate`. The same placeholder is in the `*.backend.tfvars`. Create the bucket once:

1. In `_terraform.tf`, comment out the `backend "s3"` block.
2. Uncomment the resource `aws_s3_bucket.tfstate` together with versioning, encryption, and the public access block, and set the bucket name.
3. Apply with local state.
4. Comment the resource out again, enable the backend, and run `scripts/tf init`. Terraform asks about the migration; alternatively run `terraform init -migrate-state` with the same `-backend-config` as the script.

During a normal apply the resource stays commented out, so that each environment leaves the shared state bucket alone.

Bucket names in the `*.tfvars` start with `REPLACE_ME`. S3 rejects uppercase letters, so an apply fails until the names are replaced.

### 4. Init, plan, and apply

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
```

`plan` writes `environments/<env>.tfplan`. `apply` applies only that file and deletes it afterwards. If no plan file is present, `apply` stops.

The same commands work for another environment than the checked-out branch. `-e` and `--env` are equivalent and come before the subcommand. If the name differs from the branch, the script writes a note to stderr and continues.

```bash
scripts/tf -e dev plan
scripts/tf --env prod apply
```

Further commands, including `import` and secret var-files, are under [Commands](#commands).

## On a branch

Check out `develop` for day-to-day work. Changes move by merge from `develop` to `staging` and from `staging` to `main`.

Your own resources go in as further `.tf` files next to [`example-s3-bucket.tf`](example-s3-bucket.tf). New variables go into `_variables.tf` and into `environments/<env>.tfvars`.

To try something without changing `dev`, create a `preview/<name>` branch. See [Preview environment](#preview-environment).

Once the [pipeline](docs/pipeline.md) is in place, a pull request runs the same plan and apply from a comment.

## Commands

```bash
scripts/tf init
scripts/tf plan
scripts/tf apply
scripts/tf import aws_s3_bucket.example my-bucket
```

```bash
scripts/tf -e dev plan
scripts/tf --env prod apply
scripts/tf --env preview-feature123 init
```

`environments/<env>.secrets.tfvars` is passed in automatically once the file exists. It is gitignored. A template lives at `environments/secrets.tfvars.example`. In the pipeline, the secret `TF_SECRETS_TFVARS` writes this file when it is set. See [docs/pipeline.md](docs/pipeline.md).

## Files

- `_terraform.tf` — Terraform version, provider, S3 backend
- `_providers.tf` — all providers for the project are defined here
- `_variables.tf` — variables
- `_locals.tf` — shared locals and tags
- `_outputs.tf` — outputs
- `example-s3-bucket.tf` — private example bucket
- `environments/<env>.tfvars` — variables for the environment
- `environments/<env>.backend.tfvars` — backend configuration
- `environments/<env>.secrets.tfvars` — optional secrets, not in Git
- `environments/<env>.tfplan` — plan file, not in Git
- `pipeline.json` — tool, stages, branch mapping, and preview mode, for local runs and GitHub Actions
- `scripts/setup` — writes `pipeline.json` and the preview workflow trigger
- `.github/workflows/terraform-commands.yml.template` — comment workflow. `scripts/setup` writes the `.yml` when GitHub Actions are enabled
- `.github/workflows/terraform-preview.yml.template` — preview workflow, written the same way when preview is on
- `.github/actions/tf-run/` — shared steps for OIDC, the lock, and `scripts/tf`

`bucket`, `key`, and `region` live in the backend tfvars. The state key is the same for every environment (`terraform-aws-template/terraform.tfstate`). The workspace does the separation, for example `env:/prod/terraform-aws-template/terraform.tfstate`.

## Preview environment

With the shipped prefix mode:

```bash
git checkout develop
git checkout -b preview/feature123
scripts/tf init
```

If the files are missing, `init` copies the templates to `environments/preview-feature123.tfvars` and `environments/preview-feature123.backend.tfvars` and stops. After you adjust the values, run `init` again, then `plan` and `apply`.

The same files are created with `scripts/tf -e preview-feature123 init`, including from another branch. A suffix `feature/foo-preview` becomes the workspace `preview-feature-foo`. A label on a pull request does not select a workspace locally; use `-e` or `--env`. The workspace name is still `preview-<slug>`, with `/` in the branch turned into `-`.

## License

This template is released under the MIT License. The copyright notice and the license text are in [LICENSE.md](LICENSE.md).
