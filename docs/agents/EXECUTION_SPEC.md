# Agent Execution Specification

This specification gives Codex and Claude the minimum context needed to execute end-to-end work without additional prompts. Keep it close at hand when drafting tasks or planning multi-step runs.

## 1. Mission & Scope

- **Product outcome:** Deliver and operate the `ai-dev-platform` monorepo, which bundles a marketing-facing Next.js 14 web app, Terraform-managed Google Cloud infrastructure, and hardened CI/CD pipelines.
- **Primary users:** Platform engineers provisioning secure AI delivery pipelines; product engineers iterating on the web experience; security engineers verifying guardrails.
- **Agent mandate:** Implement features, infrastructure, security controls, and automation end-to-end while preserving supply-chain guarantees and CI/CD stability.
- **Out of scope:** Authoring entirely new microservices, altering production IAM policies without sign-off, or dismantling security tooling (gitleaks, semgrep, Binary Authorization, etc.).

## 2. Quality Objectives

- **Security first:** Never regress scanning, signing, or Binary Authorization gates. Default to least privilege and short-lived credentials.
- **Test-driven delivery:** Introduce or update unit/E2E coverage for every feature or fix (`docs/TDD_GUIDE.md`). Failing tests must block completion.
- **Operational clarity:** Automation scripts must emit actionable logs, exit non-zero on failure, and integrate with existing scripts rather than duplicating them.
- **Traceability:** Capture decisions in code comments sparingly, commit messages (Conventional Commits), and updates to `config/task-context.json`.
- **Resilience:** Prefer idempotent scripts, declarative manifests, and deterministic builds. Handle missing secrets by stubbing, documenting, or mocking as prescribed in the playbook.

## 3. Architecture Overview

| Domain                  | Location                                                         | Responsibilities                                                                                                                                                               |
| ----------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Web application**     | `apps/web`                                                       | Next.js 14 app router project. UI lives under `src/app`, shared utilities under `src/lib`, tests in `src/__tests__`, Playwright specs in `tests/e2e`.                          |
| **Infrastructure**      | `infra/terraform`                                                | Terraform modules (`modules/`) and environment overlays (`envs/`) provisioning GKE Autopilot, networking, Artifact Registry, and WIF.                                          |
| **Kubernetes delivery** | `deploy/k8s`                                                     | Kustomize base + overlays that inject digests, identity bindings, and Gateway routes.                                                                                          |
| **Automation scripts**  | `scripts`                                                        | Onboarding (`setup-all.sh`), syncing (`git-sync-check.sh`), PR management (`push-pr.sh`, `monitor-pr.sh`), task context (`task-context.sh`), and validation (`test-suite.sh`). |
| **Docs & runbooks**     | `docs`                                                           | Architecture deep dives, supply-chain guardrails, onboarding, agent guidance, and this spec.                                                                                   |
| **Config**              | `config/task-context.json`, `config/editor-extensions.lock.json` | Shared state for task definition and editor extension provenance.                                                                                                              |

### Key Entry Points

- `apps/web/src/app/page.tsx` renders the marketing landing page; use `apps/web/src/__tests__/page.test.tsx` for regression coverage.
- `infra/terraform/modules/*` define reusable stacks; environment-specific values live in `infra/terraform/envs/{staging,production}`.
- `deploy/k8s/overlays/*` patch the base manifests per environment.
- `scripts/test-suite.sh` orchestrates linting, type checking, unit, and Playwright suites; prefer extending this script over creating divergent runners.

## 4. Accepted Workflows & Commands

| Goal                | Command(s)                                                            | Notes                                                                                               |
| ------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Show active context | `./scripts/task-context.sh --show`                                    | Keep `lastUpdated` in ISO-8601; update goals/todos as progress is made.                             |
| One-shot setup      | `./scripts/setup-all.sh`                                              | Installs tooling, bootstraps infra, hardens repo, and aligns editor extensions.                     |
| Focused install     | `pnpm install`                                                        | Run inside repo root. Node 20.x with Corepack-managed pnpm 9 is expected.                           |
| Local dev server    | `pnpm --filter @ai-dev-platform/web dev`                              | Exposes app at http://localhost:3000.                                                               |
| Lint                | `pnpm lint`                                                           | Aggregates ESLint for all workspaces.                                                               |
| Type check          | `pnpm type-check`                                                     | Runs TypeScript program-wide.                                                                       |
| Unit tests          | `pnpm --filter @ai-dev-platform/web test`                             | Uses Jest + Testing Library. Add snapshots cautiously.                                              |
| E2E tests           | `pnpm --filter @ai-dev-platform/web test:e2e`                         | Playwright; respects `E2E_TARGET_URL` when provided.                                                |
| Full validation     | `./scripts/agent-validate.sh` (preferred) / `./scripts/test-suite.sh` | Aggregates lint, type-check, unit, and Playwright tests with consistent logging and cache handling. |
| PR lifecycle        | `./scripts/push-pr.sh` → `./scripts/monitor-pr.sh`                    | Ensures CI parity and auto-merge, collects evidence.                                                |

## 5. Data, Fixtures & Samples

- Canonical UI feature data lives in `apps/web/src/app/page.tsx`. A reusable fixture for testing resides at `fixtures/web/feature-cards.json`.
- Playwright projects read configuration from `apps/web/playwright.config.ts`; capture recordings in `apps/web/test-results`.
- Infrastructure samples (Terraform `tfvars`, Kustomize overlays) should reference non-secret placeholder values and document required secrets using comments or `README`s within each directory.

## 6. External Dependencies & Secrets

- **Google Cloud:** Requires project ID, Artifact Registry, and WIF provider outputs. Never hardcode secrets; leverage Terraform outputs and GitHub environment secrets via `configure-github-env.sh`.
- **Docker/Container registry:** Use distroless base images as defined in Dockerfiles; scanning handled by CI (Trivy, Grype).
- **Playwright browsers:** Bootstrapped with `pnpm --filter @ai-dev-platform/web exec playwright install --with-deps`.
- **CI pipelines:** Defined in `.github/workflows`; adjust using reusable jobs and respect security scanners.

## 7. Definition of Done

1. Task context updated with goal, acceptance criteria, remaining TODOs, and `lastUpdated`.
2. Feature covered by passing unit/E2E tests, with `./scripts/test-suite.sh` successfully executed.
3. Relevant docs updated (architecture notes, runbooks, or decision records).
4. Automation scripts reflect new workflows (add commands or document how to run them).
5. Git status clean; `./scripts/git-sync-check.sh` reports no drift.
6. Branch pushed via `./scripts/push-pr.sh`, monitored until merge with evidence captured.

## 8. References

- `docs/AGENT_HANDBOOK.md` – step-by-step operating loop.
- `docs/AGENT_PROTOCOLS.md` – collaboration and safety guardrails.
- `docs/agents/DECISION_PLAYBOOK.md` – ambiguity resolution.
- `docs/agents/RISK_REGISTER.md` – known hazards and mitigation.
- `docs/agents/PROMPT_TEMPLATE.md` – boilerplate kickoff prompt.
- `docs/agents/QUALITY_CHECKLIST.md` – pre-PR validation list.
