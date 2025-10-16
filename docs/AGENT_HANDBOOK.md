# Autonomous Agent Handbook

This document distills the end-to-end process Codex and Claude agents must follow to deliver features autonomously. Review the following companion docs before you begin:

- `docs/agents/EXECUTION_SPEC.md` – canonical goals, architecture map, done definition.
- `docs/agents/DECISION_PLAYBOOK.md` – ambiguity resolution rules.
- `docs/agents/RISK_REGISTER.md` – known hazards and mitigations.
- `docs/agents/QUALITY_CHECKLIST.md` – pre-PR validation.
- `docs/agents/PROMPT_TEMPLATE.md` – kickoff prompt scaffold.

## 1. Align on Scope

```bash
./scripts/task-context.sh --show
```

- Use `./scripts/task-context.sh --show` to review current goals, acceptance criteria, and remaining TODOs. Ensure the context references the spec and playbook entries you rely on.
- Update the context as you plan new work (`--set` and `--clear`) so the repo reflects the project state.
- Capture requirements in `config/task-context.json`; keep `lastUpdated` fresh so reviewers know the plan is current.

## 2. Bootstrapping (first run)

```bash
./scripts/setup-all.sh
```

This installs dependencies, updates and verifies editor extensions, and runs onboarding/infra/hardening.

## 3. Follow the TDD Loop

1. Add or modify a failing unit (`apps/web/src/__tests__`) or E2E test (`apps/web/tests/e2e`).
2. Run the test to observe the failure.
3. Implement the smallest change needed to pass.
4. Run `./scripts/test-suite.sh` (or `./scripts/agent-validate.sh` for recorded output) to execute lint, type-check, unit, and Playwright suites.
5. Repeat until the feature is complete and all tests are green.

## 4. Maintain Git Hygiene

- Work on a feature branch, never on `main`.
- Commit frequently with Conventional Commits and clear messages.
- Before pushing, ensure `./scripts/git-sync-check.sh` reports no drift.

## 5. Push via Automation

```bash
./scripts/push-pr.sh
./scripts/monitor-pr.sh
```

`push-pr.sh` reruns the full suite, enforces test coverage (unless `ALLOW_NO_TEST_CHANGES=1` is documented), pushes the branch, annotates the PR with test/extension/git-sync data, and enables auto-merge. `monitor-pr.sh` watches until GitHub merges.

## 6. After Merge

- Update the task context (`task-context.sh --set remainingTodos ...`).
- If needed, replay a state on another machine with `./scripts/replay-state.sh <commit>`.

Obey these steps and the CI/CD pipeline will keep `main` stable while agents iterate autonomously.
