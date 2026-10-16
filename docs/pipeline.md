# GitHub pipeline

Optional setup on top of the branch mapping in the [README](../README.md). The pipeline runs `scripts/tf` in GitHub Actions. It signs in to AWS with OIDC, so the repository holds no long-lived access key.

Stages, the branch mapping, the preview mode, and the choice of Terraform or OpenTofu live in [`pipeline.json`](../pipeline.json) at the repository root. The same file is what `scripts/tf` reads locally. This page covers the workflows, the IAM roles, and the GitHub settings.

## Enable the workflows

`scripts/setup` asks whether GitHub Actions should run. Yes writes the files GitHub starts:

- `.github/workflows/terraform-commands.yml` for `/tf plan`, `/tf apply`, and `/tf unlock`
- `.github/workflows/terraform-cleanup.yml`, which runs when a pull request closes
- `.github/workflows/terraform-preview.yml` when preview is not off

The `.yml.template` files stay. GitHub ignores them, because it only starts files that end in `.yml` or `.yaml`. No leaves those templates and removes the `.yml` files if they are present. In this template the Terraform workflows stay off. The only active workflow is `.github/workflows/ci.yml`, which lints the template itself without AWS access.

GitHub reads comment workflows from the default branch. A push preview reads the workflow from the preview branch. A label preview and the cleanup read it from the pull request.

## How a run picks the workspace

The code is always the commit of the pull request or of the push. Comment commands and the cleanup read `pipeline.json` from the default branch, so a mapping change in a pull request applies after the merge. The pipeline passes `-e` to `scripts/tf` with the workspace from that file:

- If the head matches the preview rule, that preview applies, even when the pull request targets another stage.
- Otherwise the target branch applies. With the shipped file, a pull request into `main` hits `prod`.
- An unknown target branch stops the run.

`preview.mode` is one of:

- `prefix` — head `preview/<name>` becomes workspace `preview-<name>`. One path segment after the prefix.
- `suffix` — a branch that ends with the suffix, such as `feature/foo-preview`, becomes `preview-feature--foo`. Each `/` becomes `--`.
- `label` — a pull request that carries the configured label uses the head branch the same way: `feature/foo` becomes `preview-feature--foo`. `/tf plan`, `/tf apply`, and `/tf unlock` follow that label. Locally there is no label, so `scripts/tf` needs `-e`.
- `off` — no preview. This is the shipped mode.

In `suffix` and `label` mode, branch path segments must not be empty, start or end with `-`, or contain `--`. That keeps the mapping unique: two branches never share a preview workspace.

## Comments

Comments on a pull request, exact and with write access to the repository:

- `/tf plan` plans and writes the output as a reply in the pull request. The binary plan file is stored in the state bucket under `<key-dir>/pr-plans/<workspace>.tfplan`, tagged with the pull request and the commit.
- `/tf apply` applies exactly that plan. A new commit needs a new plan.
- `/tf unlock` releases the lock without applying and deletes the saved plan.

Forks are excluded.

Apply happens in the pull request, before the merge. Merging deploys nothing. The intended order is `/tf plan`, review, `/tf apply`, merge. If a pull request is merged without `/tf apply`, the branch and the environment drift apart until the next pull request plans against that workspace and shows the difference.

Apply always runs in a GitHub environment: the stage name, or `preview` for every preview. That environment supplies the AWS role for the apply. When the stage has `protected: true` in `pipeline.json`, apply waits for the environment's required reviewers. If that environment has no required reviewers, `/tf apply` refuses to run and says so in the pull request, so a missing GitHub setting can never skip the approval. Plan and unlock do not wait.

## Lock

At most one pull request holds the lock per workspace. The lock lives in the state bucket beside the state key. For the key `terraform-aws-template/terraform.tfstate`, that is `terraform-aws-template/pr-locks/<workspace>.json`. `/tf plan` creates it. A second pull request against the same workspace gets no plan, and a comment with the link to the pull request that holds the lock. `/tf apply` runs only for the pull request and the commit recorded in the lock. If the plan fails, the lock is released. If apply fails, the lock stays.

After a successful `/tf apply` the lock stays with the pull request. It is released when the pull request closes, or by `/tf unlock`. The reason: the apply ran the code of the pull request, but the stage branch does not contain it until the merge. If the lock were released at that point, another pull request could plan against the stage branch, see the applied change as something to undo, and apply that. Holding the lock until the merge closes that window. The cost is that an applied pull request that stays open blocks the workspace for everyone else; merge it, or run `/tf unlock` if it is abandoned.

When a pull request closes, merged or not, the cleanup workflow releases its lock and deletes its saved plan. A lock with a running apply stays; release it with `/tf unlock` afterwards.

## Preview runs

With `prefix` or `suffix`, a push of a matching branch runs init, plan, and apply, without a comment. With `label`, adding the label runs the same steps, and a later push to that pull request runs them again while the label is still there. If a pull request holds the lock for this workspace, the run stops.

All previews use the shared `environments/preview.tfvars` and `environments/preview.backend.tfvars`, unless the branch adds `environments/preview-<name>.*`. Resource names contain the workspace, so previews do not collide.

When the pull request of a preview closes, the cleanup workflow destroys the preview with the code of the pull request's last commit and deletes the workspace. A push preview without a pull request is destroyed by hand: `scripts/tf -e preview-<name> plan -destroy`, then `scripts/tf -e preview-<name> apply`.

The workflow `on:` block cannot be read from `pipeline.json` at runtime. `scripts/setup` writes it into `.github/workflows/terraform-preview.yml.template`, and into `.github/workflows/terraform-preview.yml` when GitHub Actions are enabled.

## Security model

Each job gets credentials only for what it does:

| Job | GitHub environment | Role from | OIDC subject |
| --- | --- | --- | --- |
| `/tf plan`, `/tf unlock`, lock release on close | none | repository variable `AWS_ROLE_ARN` | `ref:refs/heads/<default-branch>`, `pull_request` |
| `/tf apply` on a stage | the stage, for example `prod` | environment variable `AWS_ROLE_ARN` | `environment:prod` |
| preview push, label, apply, destroy | `preview` | environment variable `AWS_ROLE_ARN` of `preview` | `environment:preview` |

- The repository-level role is the **plan role**. Give it read access only, plus the state bucket paths below. It never needs write access to your resources.
- Every GitHub environment has its own **apply role**. Only the `prod` environment's role can change prod, and only a job in that environment, after its reviewers approved, can assume it.
- If an environment has no `AWS_ROLE_ARN` of its own, GitHub falls back to the repository variable, that is the read-only plan role, and the apply fails instead of running with too much access.
- Secrets are per environment: `TF_SECRETS_TFVARS_<ENV>` as repository secrets, for example `TF_SECRETS_TFVARS_PROD` and `TF_SECRETS_TFVARS_PREVIEW`. A run only receives the secret of its own environment. `-` in the environment name becomes `_`.

What remains by design:

- `/tf plan` runs the code of the pull request, including `scripts/tf`. Anyone with write access can therefore read what the plan role can read, and the secret of the target stage. Keep the plan role read-only and keep secrets in the stage that needs them.
- The plan role writes the saved plan and the lock. Reviewers of a protected apply should check the plan comment of the commit they approve.
- Previews share the `preview` role. Scope it to preview resources, for example by name prefix `<name_prefix>-preview-*`.

## OIDC sign-in

### Provider

Once per AWS account, if the provider is still missing. The API requires the thumbprints. AWS does not check them for this provider.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
```

### Subject format

`ORG` and `REPO` are the GitHub name, and `ACCOUNT_ID` is the AWS account number. The audience is `sts.amazonaws.com`.

Repositories created after July 15, 2026, and repositories that opted in, use immutable subjects with the owner and repository IDs: `repo:ORG@<owner-id>/REPO@<repo-id>:environment:prod`. `gh api repos/ORG/REPO --jq '"\(.owner.id) \(.id)"'` prints both IDs. The examples below use the previous format; adjust them if your repository uses the new one.

### Plan role

Trust policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": [
                        "repo:ORG/REPO:ref:refs/heads/main",
                        "repo:ORG/REPO:pull_request"
                    ]
                }
            }
        }
    ]
}
```

`ref:refs/heads/main` is the default branch, the subject of every comment workflow. `pull_request` is the cleanup on close.

Permissions: read access to the resources you plan (for example the managed policy `ReadOnlyAccess`, or a narrower one), plus the state bucket:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StateList",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate"
        },
        {
            "Sid": "StateRead",
            "Effect": "Allow",
            "Action": ["s3:GetObject"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate/env:/*"
        },
        {
            "Sid": "StateLockFile",
            "Effect": "Allow",
            "Action": ["s3:PutObject", "s3:DeleteObject"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate/env:/*.tflock"
        },
        {
            "Sid": "PullRequestLocksAndPlans",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": [
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-locks/*",
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-plans/*"
            ]
        }
    ]
}
```

### Apply roles

One role per GitHub environment. The trust policy is the same as above, with a single subject:

```json
"token.actions.githubusercontent.com:sub": "repo:ORG/REPO:environment:prod"
```

For previews, the subject is `repo:ORG/REPO:environment:preview`.

Permissions: whatever your resources need to be created and changed, plus the state of that environment. For `prod`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StateList",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate"
        },
        {
            "Sid": "State",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate/env:/prod/*"
        },
        {
            "Sid": "PullRequestLocksAndPlans",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": [
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-locks/prod.json",
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-plans/prod.tfplan"
            ]
        }
    ]
}
```

For the `preview` role, use `env:/preview-*`, `pr-locks/preview-*`, and `pr-plans/preview-*`. Destroying a preview also deletes its workspace, which deletes its state object.

```bash
aws iam create-role \
  --role-name REPLACE_ME-github-terraform-prod \
  --assume-role-policy-document file://trust-prod.json
aws iam put-role-policy \
  --role-name REPLACE_ME-github-terraform-prod \
  --policy-name terraform-state \
  --policy-document file://state-prod.json
```

## GitHub settings

Under Settings → Secrets and variables → Actions:

- Repository variable `AWS_ROLE_ARN`: the plan role. This is not a secret.
- Optional repository variable `AWS_REGION`; otherwise the pipeline uses `eu-central-1`.
- Optional repository variable `EXECUTABLE`, only to override `tool` from `pipeline.json` for Actions.
- Optional repository secrets `TF_SECRETS_TFVARS_<ENV>`, written to `environments/<env>.secrets.tfvars` when set.

Under Settings → Environments, for every stage and for `preview` if previews are on:

- Environment variable `AWS_ROLE_ARN`: the apply role of that environment.
- For every stage with `protected: true`: required reviewers. With the shipped file that is `prod`.

GitHub creates a missing environment on its first use, without a role or reviewers. Create them before the first apply.

### What each run does

The workflow permission `id-token: write` issues the JWT. `aws-actions/configure-aws-credentials` exchanges it for short-lived credentials of the role from `vars.AWS_ROLE_ARN`, which is the environment's variable in an environment job and the repository variable otherwise. After that, `scripts/tf` and the lock run with these credentials. Without the variable, or without a matching subject, the run ends at sign-in, before Terraform starts.
