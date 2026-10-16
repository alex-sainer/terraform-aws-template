# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. You will get a reply within seven days.

Include what you found, how to reproduce it, and which part of the repository is affected.

## What counts

This repository is a template. The parts that run with AWS credentials or react to pull request events are the ones that matter most:

- `.github/actions/tf-run/` — `gate.sh` (who may run `/tf` commands), `lock.sh` (the workspace lock in the state bucket), `run.sh` (plan, apply, and the saved plan file)
- `.github/workflows/*.yml.template` — triggers, permissions, and the environment that supplies the apply role
- `scripts/tf` and `scripts/pipeline.sh` — the branch-to-workspace mapping that decides which state is touched
- `docs/pipeline.md` — the IAM trust and permission policies

Examples of reports we want: a way for someone without write access to trigger a plan or apply, a way to apply a plan from another commit or pull request, a way to reach another environment's secret or role, a lock that can be bypassed, or an IAM policy in the docs that grants more than it says.

## What is by design

`docs/pipeline.md`, section "Security model", lists what the design accepts: `/tf plan` runs the code of the pull request with the read-only plan role, so anyone with write access can read what that role can read. If you think one of those trade-offs is wrong, open a regular issue; that is a design discussion, not a vulnerability.

## Supported versions

Only the `main` branch is maintained. Repositories created from this template have to adopt fixes themselves; a release note on the fixing pull request says what to copy.
