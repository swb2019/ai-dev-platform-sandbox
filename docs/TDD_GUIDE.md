# Test-Driven Development Workflow

Agents must follow a strict test-driven loop when modifying this repository:

1. **Add or adjust a failing test** first. Unit tests live under `apps/web/src/__tests__`, while end-to-end tests live under `apps/web/tests/e2e`.
2. **Run the test** to capture the failure: `pnpm --filter @ai-dev-platform/web test` or `pnpm --filter @ai-dev-platform/web test:e2e` as appropriate.
3. **Implement the change** needed to make the test pass. Update the task manifest (if you completed or added TODOs) via `./scripts/task-context.sh --set remainingTodos "...;..."`.
4. **Run the full suite** via `./scripts/test-suite.sh`. This also serves as the green gate before committing.
5. **Use `./scripts/push-pr.sh`** to run the suite again, verify editor extensions, push the branch, annotate the PR, and enable auto-merge. `scripts/push-pr.sh` will refuse to continue if application code changed without any test updates (override with `ALLOW_NO_TEST_CHANGES=1` only when justified and documented).

Following this loop ensures autonomous agents keep the repository healthy and maintain full CI/CD coverage.
