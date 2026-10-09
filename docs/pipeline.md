# GitHub pipeline

Optional setup on top of the branch mapping in the [README](../README.md). The pipeline runs `scripts/tf` in GitHub Actions. It signs in to AWS with OIDC, so the repository holds no long-lived access key.

Stages, the branch mapping, the preview mode, and the choice of Terraform or OpenTofu live in [`pipeline.json`](../pipeline.json) at the repository root. The same file is what `scripts/tf` reads locally. This page covers the workflows, the IAM role, and the GitHub settings. `scripts/setup` writes the file, the preview workflow trigger, and the active workflow files when GitHub Actions are enabled. `scripts/setup --render` refreshes the trigger from the current file, and the active workflow files when they are already on.

## Enable the workflows

`scripts/setup` asks whether GitHub Actions should run. Yes writes the files GitHub starts:

- `.github/workflows/terraform-commands.yml` for `/tf plan`, `/tf apply`, and `/tf unlock`
- `.github/workflows/terraform-preview.yml` when preview is not off

The `.yml.template` files stay. GitHub ignores them, because it only starts files that end in `.yml` or `.yaml`. No leaves those templates and removes the `.yml` files if they are present. In this template the workflows stay off, so the `.template` suffixes remain and no `.yml` is committed.

GitHub reads comments from the default branch. A push preview reads the workflow from the preview branch. A label preview reads the workflow from the default branch, because `pull_request` uses that copy. The shipped default branch is `main`.

## How a run picks the workspace

The code is always the commit of the pull request or of the push. Comment commands read `pipeline.json` from the default branch, so a mapping change in a pull request applies after the merge. The pipeline passes `-e` to `scripts/tf` with the workspace from that file:

- If the head matches the preview rule, that preview applies, even when the pull request targets another stage.
- Otherwise the target branch applies. With the shipped file, a feature branch into `develop` hits `dev`, `develop` into `staging` hits `staging`, and `staging` into `main` hits `prod`.
- An unknown target branch stops the run.

`preview.mode` is one of:

- `prefix` — head `preview/<name>` becomes workspace `preview-<name>`. One path segment after the prefix. This is the shipped mode.
- `suffix` — a branch that ends with the suffix, such as `feature/foo-preview`, becomes `preview-feature-foo`. `/` in the remaining branch becomes `-`.
- `label` — a pull request that carries the configured label uses the head branch the same way: `feature/foo` becomes `preview-feature-foo`. `/tf plan`, `/tf apply`, and `/tf unlock` follow that label. Locally there is no label, so `scripts/tf` needs `-e`.
- `off` — no preview. The setup removes an active preview workflow if one is present.

## Comments

Comments on a pull request, exact and with write access to the repository:

- `/tf plan` plans and writes the output as a reply in the pull request. The binary plan file is stored as the artifact `tfplan-<pr>-<sha>-<workspace>`.
- `/tf apply` applies exactly that artifact. A new commit needs a new plan.
- `/tf unlock` releases the lock without applying. The saved plan is no longer valid afterwards.

Forks are excluded. Apply waits for approval when the stage in `pipeline.json` has `protected: true`. The GitHub environment has the workspace name. Plan and unlock do not wait. With the shipped file that pause is `prod` and `staging`. `dev` and `preview-*` do not have it.

## Lock

At most one pull request holds the lock per workspace. The lock lives in the state bucket beside the state key. For the key `terraform-aws-template/terraform.tfstate`, that is `terraform-aws-template/pr-locks/<workspace>.json`. `/tf plan` creates it. A second pull request against the same workspace gets no plan, and a comment with the link to the pull request that holds the lock. `/tf apply` runs only for the pull request and the commit recorded in the lock, and releases it afterwards. If the plan fails, the lock is released. If apply fails, the lock stays.

## Preview runs

With `prefix` or `suffix`, a push of a matching branch runs init, plan, and apply, without a comment. With `label`, adding the label runs the same steps, and a later push to that pull request runs them again while the label is still there. Removing the label does not destroy the workspace. If the env files are missing on the branch, `init` only creates the templates and the run ends before anything is applied. The files have to be on the branch. If a pull request holds the lock for this workspace, the run stops.

The workflow `on:` block cannot be read from `pipeline.json` at runtime. `scripts/setup` writes it into `.github/workflows/terraform-preview.yml.template`, and into `.github/workflows/terraform-preview.yml` when GitHub Actions are enabled. `scripts/setup --render` refreshes the active `.yml` files when `terraform-commands.yml` is already present.

## OIDC sign-in

The pipeline takes the repository variable `AWS_ROLE_ARN` and exchanges a GitHub JWT for short-lived credentials.

### Provider and role

Once per AWS account, if the provider is still missing. The API requires the thumbprints. AWS does not check them for this provider.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
```

Create a role that trusts only these subjects. `ORG` and `REPO` are the GitHub name, and `ACCOUNT_ID` is the AWS account number. The audience is `sts.amazonaws.com`.

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
                        "repo:ORG/REPO:environment:prod",
                        "repo:ORG/REPO:environment:staging",
                        "repo:ORG/REPO:ref:refs/heads/preview/*"
                    ]
                }
            }
        }
    ]
}
```

`repo:ORG/REPO:ref:refs/heads/main` covers `/tf plan`, `/tf unlock`, and apply without a GitHub environment (`dev`, and a preview comment). A comment workflow runs on the default branch, so the subject is that branch. `environment:prod` and `environment:staging` apply once apply sets the environment; the subject then replaces the branch. `preview/*` covers a push to `preview/<name>`. After `scripts/setup` changes stages or the preview mode, the script prints the subjects that match the new file. A label preview adds `repo:ORG/REPO:pull_request`, because a `pull_request` workflow does not send the branch as the subject. A suffix preview uses a subject that ends with the suffix.

```bash
aws iam create-role \
  --role-name REPLACE_ME-github-terraform \
  --assume-role-policy-document file://trust.json
```

### Role permissions

The role needs the state bucket from `environments/*.backend.tfvars`: state under `env:/<workspace>/`, the Terraform lock file, and `pr-locks/`. Adjust the bucket name and the key prefix if you changed them. The example bucket from `example-s3-bucket.tf` needs its own permissions, matching the names in the tfvars.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StateList",
            "Effect": "Allow",
            "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
            "Resource": "arn:aws:s3:::REPLACE_ME-tfstate"
        },
        {
            "Sid": "StateObjects",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": [
                "arn:aws:s3:::REPLACE_ME-tfstate/env:/*",
                "arn:aws:s3:::REPLACE_ME-tfstate/terraform-aws-template/pr-locks/*"
            ]
        }
    ]
}
```

```bash
aws iam put-role-policy \
  --role-name REPLACE_ME-github-terraform \
  --policy-name terraform-state \
  --policy-document file://state.json
```

### GitHub

Under Settings → Secrets and variables → Actions → Variables, set the variable `AWS_ROLE_ARN` to the role ARN. This is not a secret. Optionally set `AWS_REGION`; otherwise the pipeline uses `eu-central-1`. The tool comes from `tool` in `pipeline.json`. Set the variable `EXECUTABLE` only to override that for Actions; leave it unset otherwise.

If runs need `environments/<env>.secrets.tfvars`, set the secret `TF_SECRETS_TFVARS`. The pipeline writes that value to the secrets file when the secret is set.

Create a GitHub environment for every stage with `protected: true` and set required reviewers. With the shipped file those are `prod` and `staging`. If `AWS_ROLE_ARN` is also set there, that role applies only to the protected apply. Its trust policy then needs the subject `repo:ORG/REPO:environment:<name>`, and the same state permissions, because apply reads the state and releases the lock.

### What each run does

The workflow permission `id-token: write` issues the JWT. `aws-actions/configure-aws-credentials` exchanges it for short-lived credentials of the role from `vars.AWS_ROLE_ARN`. After that, `scripts/tf` and the lock run with these credentials. Without the variable, or without a matching subject, the run ends at sign-in, before Terraform starts.
