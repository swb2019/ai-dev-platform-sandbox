# Quality Checklist

Run through this list before opening a pull request or ending an autonomous session. Treat each checkbox as mandatory unless explicitly waived in the task context.

- [ ] `config/task-context.json` reflects latest goal, acceptance criteria, remaining TODOs, and ISO-8601 `lastUpdated`.
- [ ] All new behaviour is covered by unit and/or E2E tests; run `./scripts/test-suite.sh` successfully.
- [ ] Lint (`pnpm lint`) and type checks (`pnpm type-check`) pass without warnings requiring suppression.
- [ ] Relevant docs updated (spec, playbooks, risk register, README excerpts, or module-level notes).
- [ ] Secrets are not committed; Terraform vars and configs reference placeholders where necessary.
- [ ] `./scripts/git-sync-check.sh` reports sync complete; clean `git status`.
- [ ] Branch pushed using `./scripts/push-pr.sh`; monitoring initiated via `./scripts/monitor-pr.sh`.
- [ ] Final hand-off message includes summary of changes, validations run, sync status, and outstanding risks.
