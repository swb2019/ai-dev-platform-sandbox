# AI Agent Protocols

This document defines how autonomous and semi-autonomous agents collaborate on the AI Dev Platform codebase.

## Operating Loop: Plan → Execute → Validate → Self-Correct

1. **Plan** — Gather context, identify constraints, outline multi-step work before touching code.
2. **Execute** — Perform the planned steps with minimal deviation; document rationale for significant changes.
3. **Validate** — Run required checks (unit/integration/E2E tests, linters, type-checkers) and capture evidence.
4. **Self-Correct** — Compare outcomes against the objective, remediate regressions, and iterate until acceptance criteria are met or blockers are escalated.

Agents must never skip a phase. If a phase cannot be completed (e.g., missing credentials), pause and request human intervention with full context.

## Security Guardrails

- Respect organizational security tooling (gitleaks, semgrep, supply chain scanners, etc.); do not disable, bypass, or suppress findings without documented approval.
- Use least privilege. Never mint long-lived credentials or weaken IAM, RBAC, firewall, or runtime policies.
- Keep secrets out of source control, logs, and pull requests. Use secret managers or GitHub Actions secrets.
- Treat the staging and production clusters as protected systems. Operational changes require review, auditability, and rollback plans.

## Git & Collaboration Protocol

- Use Conventional Commits (`type(scope?): subject`). Populate PR descriptions with context, testing evidence, and risk assessment.
- Open pull requests early for visibility. Request reviewers from the owning team when touching shared infrastructure or security-critical code.
- Rebase onto `main` before merge, resolve conflicts locally, and ensure the branch passes CI (lint, unit, integration, E2E, supply chain checks).
- Commit work on feature branches and finish by running `./scripts/push-pr.sh` to push, open the PR, and enable auto-merge.
- Squash merges are preferred unless an alternative strategy is approved for traceability.

## Validation Expectations

- Automated validations (lint, type-check, unit tests, Playwright E2E) must run locally or in CI and succeed before requesting review.
- When introducing new features or fixing regressions, add or update tests that prove the change. Absence of tests must be justified and approved.
- Capture relevant logs, screenshots, or run outputs when investigating incidents; include them in tickets or PRs for audit trails.
- Production incidents trigger a postmortem with action items to prevent recurrence; agents assist by collecting evidence and drafting remediation steps.

## Agent Tooling & Notes

- Cursor-based sessions load `.cursor/agents.md`. Keep the instructions concise and update them when workflows change so Codex/Claude have current expectations.
- Agents and humans share the `./scripts/git-sync-check.sh` helper. Run it before handing off work; address any reported drift or document why it cannot be resolved.
- Claude Code does not read workspace files directly. Maintain its **Project Notes** panel with the essentials:
  - Repository summary: `ai-dev-platform` monorepo (Next.js web app + infra + scripts).
  - Required quality steps: `pnpm lint`, `pnpm type-check`, targeted unit tests, `pnpm --filter @ai-dev-platform/web test:e2e`.
  - Reminder to execute `./scripts/git-sync-check.sh` and report sync status.
    Review and refresh the note whenever workflows or quality gates change.
