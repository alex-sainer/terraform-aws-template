<!-- Thanks for the pull request. Keep it focused on one change. -->

## What and why

<!-- Which problem does this solve? Link the issue if there is one: Closes #123 -->

## Area

<!-- Tick what applies. -->

- [ ] Terraform code (`*.tf`, `environments/`, `bootstrap/`)
- [ ] `scripts/` (`tf`, `pipeline.sh`, `setup`)
- [ ] Workflows or `.github/actions/tf-run/`
- [ ] Documentation only

## Checklist

- [ ] `pre-commit run --all-files` passes
- [ ] Change to `scripts/pipeline.sh`: a test in `scripts/pipeline-test.sh` covers it
- [ ] Change to workflows or `tf-run/`: `bash scripts/lint-workflows.sh` passes
- [ ] Change to `pipeline.json` keys or `scripts/setup`: `scripts/setup --render` tested with preview `off` and one other mode
- [ ] Change in behavior: README or `docs/pipeline.md` updated in this pull request
- [ ] Secret variables are marked `sensitive = true`

## Breaking for derived repositories?

<!-- Repositories created from this template adopt changes by hand. If they have to do something
     after this merges (rename a file, change pipeline.json, update an IAM policy), say what. Otherwise: No. -->
