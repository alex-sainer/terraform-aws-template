# GitHub pipeline

Optional setup on top of the branch mapping in the [README](../README.md). The pipeline runs `scripts/tf` in GitHub Actions. It signs in to AWS with OIDC, so the repository holds no long-lived access key.

The repository, the choice of Terraform or OpenTofu, and the state bucket come from the README setup. This page covers the workflows, the IAM role, and the GitHub settings.

## Enable the workflows

The workflows live as templates under `.github/workflows/*.yml.template`. Rename them so GitHub runs them in your repository:

```bash
git mv .github/workflows/terraform-commands.yml.template .github/workflows/terraform-commands.yml
git mv .github/workflows/terraform-preview.yml.template .github/workflows/terraform-preview.yml
```

In this template the `.template` suffixes stay. GitHub only starts files that end in `.yml` or `.yaml`.

GitHub reads comments from the default branch `main`. A push to `preview/<name>` reads the workflow from that branch. The default branch stays `main`.

## How a run picks the workspace

The code is always the commit of the pull request or of the push. The pipeline passes `-e` to `scripts/tf` with the workspace chosen as follows:

- If the head starts with `preview/<name>`, that branch applies. `preview/feature123` becomes `preview-feature123`, even when the pull request targets `develop`.
- Otherwise the target branch applies: a feature branch into `develop` hits `dev`, `develop` into `staging` hits `staging`, and `staging` into `main` hits `prod`.
- An unknown target branch that is not `main`, `develop`, `staging`, or `preview/<name>` stops the run.

## Comments

Comments on a pull request, exact and with write access to the repository:

- `/tf plan` plans and writes the output as a reply in the pull request. The binary plan file is stored as the artifact `tfplan-<pr>-<sha>-<workspace>`.
- `/tf apply` applies exactly that artifact. A new commit needs a new plan.
- `/tf unlock` releases the lock without applying. The saved plan is no longer valid afterwards.

Forks are excluded. Apply on `prod` and `staging` waits for approval of the GitHub environment with the same name. Plan and unlock do not wait. `dev` and `preview-*` do not have this pause.

## Lock

At most one pull request holds the lock per workspace. The lock lives in the state bucket beside the state key. For the key `terraform-aws-template/terraform.tfstate`, that is `terraform-aws-template/pr-locks/<workspace>.json`. `/tf plan` creates it. A second pull request against the same workspace gets no plan, and a comment with the link to the pull request that holds the lock. `/tf apply` runs only for the pull request and the commit recorded in the lock, and releases it afterwards. If the plan fails, the lock is released. If apply fails, the lock stays.

## Preview pushes

A push to `preview/<name>` runs init, plan, and apply for `preview-<name>`, without a comment. If the env files are missing on the branch, `init` only creates the templates and the run ends before anything is applied. The files have to be on the branch. If a pull request holds the lock for this workspace, the push stops.

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

`repo:ORG/REPO:ref:refs/heads/main` covers `/tf plan`, `/tf unlock`, and apply without a GitHub environment (`dev`, preview comment). A comment workflow runs on the default branch, so the subject is `main`. `environment:prod` and `environment:staging` apply once apply sets the environment; the subject then replaces the branch. `preview/*` covers a push to `preview/<name>`.

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

Under Settings → Secrets and variables → Actions → Variables, set the variable `AWS_ROLE_ARN` to the role ARN. This is not a secret. Optionally set `AWS_REGION`; otherwise the pipeline uses `eu-central-1`. Optionally set `EXECUTABLE` to `tofu`.

If runs need `environments/<env>.secrets.tfvars`, set the secret `TF_SECRETS_TFVARS`. The pipeline writes that value to the secrets file when the secret is set.

Create the environments `prod` and `staging` and set required reviewers. If `AWS_ROLE_ARN` is also set there, that role applies only to the protected apply. Its trust policy then needs the subject `repo:ORG/REPO:environment:prod` or `environment:staging`, and the same state permissions, because apply reads the state and releases the lock.

### What each run does

The workflow permission `id-token: write` issues the JWT. `aws-actions/configure-aws-credentials` exchanges it for short-lived credentials of the role from `vars.AWS_ROLE_ARN`. After that, `scripts/tf` and the lock run with these credentials. Without the variable, or without a matching subject, the run ends at sign-in, before Terraform starts.
