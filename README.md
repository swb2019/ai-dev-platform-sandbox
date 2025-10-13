# ai-dev-platform

AI Dev Platform is a monorepo that packages a Next.js marketing application, shared TypeScript tooling, and the automation required to deploy onto Google Kubernetes Engine Autopilot. GitHub Actions pipelines enforce supply-chain scanning, binary authorization, and end-to-end validation before releases are promoted.

## Repository Structure

- `apps/web` – Next.js 14 App Router application styled with Tailwind CSS and Playwright end-to-end tests.
- `packages/tsconfig` – Shared TypeScript configuration presets (base + Next.js).
- `packages/eslint-config-custom` – Centralised ESLint rules consumed across the workspace.
- `deploy/k8s` – Kustomize base and overlays for staging and production Gateway API deployments.
- `infra/terraform` – Terraform modules and environment definitions for GKE Autopilot, networking, and Artifact Registry.
- `scripts` – Operational helpers including onboarding, infrastructure bootstrap, and container supply-chain automation.
- `docs` – Detailed architecture, security, deployment, and runbook references.

## Prerequisites

- Node.js 20.x with Corepack enabled (`corepack enable && corepack prepare pnpm@9.12.0 --activate`).
- PNPM 9 and Turbo (installed via workspace `devDependencies`).
- Docker daemon for local container builds.
- Google Cloud CLI (`gcloud`), Terraform CLI, and GitHub CLI (`gh`) with credentials that can manage the target project.
- Optional: Infisical CLI for secrets management during onboarding.

## Quick Start

1. **Run the end-to-end setup wrapper**
   ```bash
   ./scripts/setup-all.sh
   ```
   This orchestrates onboarding, infrastructure bootstrap, and repository hardening. Each underlying script remains interactive and idempotent, so you can re-run the wrapper whenever credentials or infrastructure need a refresh.
2. **Run the web application locally**
   ```bash
   pnpm --filter @ai-dev-platform/web dev
   ```
3. **Validate code changes**
   ```bash
   pnpm lint
   pnpm type-check
   pnpm --filter @ai-dev-platform/web test
   pnpm --filter @ai-dev-platform/web test:e2e
   ```

> Prefer running the steps individually? Execute `scripts/onboard.sh`, `scripts/bootstrap-infra.sh`, and `scripts/github-hardening.sh` in that order.

## Change Workflow

- After your branch is ready, run `./scripts/push-pr.sh`. It runs lint/type-check/test/e2e locally, pushes the branch, opens a PR against main, and enables auto-merge so GitHub waits for all protected-branch checks before merging.
- Use `./scripts/git-sync-check.sh` to confirm your branch matches `origin` before handing work off to a teammate or agent.
- Avoid direct pushes to `main`; the script above opens a PR against `main`, enables auto-merge, and lets GitHub land changes after checks pass.

## CI/CD Overview

- `.github/workflows/deploy-staging.yml` builds, scans, signs, and deploys the web image, then discovers the Gateway IP with `kubectl` and runs Playwright E2E tests (`e2e-validation` job) against the live staging environment.
- `.github/workflows/deploy-production.yml` mirrors the staging workflow for tagged releases using production credentials and overlays.
- `.github/workflows/ci.yml` gates pull requests with secret scanning, Semgrep, linting, type checks, formatting, and builds; `.github/workflows/codeql.yml` provides scheduled deep static analysis.

## Documentation

- Architecture: `docs/ARCHITECTURE.md`
- Security and compliance: `docs/SECURITY.md`
- Supply-chain hardening: `docs/SUPPLY_CHAIN.md`
- Infrastructure automation: `docs/INFRASTRUCTURE.md`
- Deployment workflow: `docs/DEPLOYMENT.md`
- Agent protocols: `docs/AGENT_PROTOCOLS.md`
- Onboarding: `docs/ONBOARDING.md`
- Release process: `docs/RELEASE_RUNBOOK.md`

Refer to these guides for environment-specific configuration, operational runbooks, and security guardrails.
