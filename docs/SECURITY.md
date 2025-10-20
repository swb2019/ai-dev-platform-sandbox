# Security Guardrails

This project enforces security scanning and code hygiene both locally and in continuous integration. The controls below are active as of September 30, 2025.

## Local Guardrails

- **Commit message linting** (`.husky/commit-msg`): every commit message must follow the Conventional Commits specification via `commitlint`.
- **Secret scanning** (`.husky/pre-commit`): `gitleaks protect --staged` runs before other checks using the project configuration in `.gitleaks.toml` (custom OpenAI, Anthropic, and Infisical detectors plus placeholder allowlists).
- **Source formatting and linting** (`lint-staged`): staged JavaScript/TypeScript files run through ESLint (no warnings allowed) and Prettier; structured data (`json`, `md`, `yaml`, `yml`, `mdx`) is validated with Prettier.
- Husky is bootstrapped by the root `prepare` script (`pnpm prepare`) and installs hooks on first dependency install.

## CI Security Gates (`.github/workflows/ci.yml`)

- **Job: security-scans** (fail-fast)
  - Installs Gitleaks v8.18.2 and runs `gitleaks detect` with redaction enabled.
  - Installs Semgrep and runs `semgrep ci --config semgrep.yml`, leveraging upstream `p/security` and `p/typescript` rulesets.
- **Job: quality-gates** (depends on `security-scans`)
  - Uses Node.js 20 and pnpm 9 with caching.
  - Executes `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm type-check`, `pnpm format:check`, and `pnpm build`.

## Deep Static Analysis (`.github/workflows/codeql.yml`)

- Weekly scheduled run plus `push`/`pull_request` on `main`.
- Builds the workspace with pnpm before running the `github/codeql-action` using the `security-extended` query suite for JavaScript/TypeScript.

## Workload Identity & Binary Authorization

- GitHub Actions deployment workflows (`deploy-staging.yml`, `deploy-production.yml`) authenticate to Google Cloud via Workload Identity Federation. OIDC tokens minted by `google-github-actions/auth@v2` are scoped to environment-specific service accounts, avoiding long-lived JSON keys.
- GKE workloads run with Kubernetes Service Accounts annotated for Workload Identity (`iam.gke.io/gcp-service-account`). The staging and production digests are injected at deploy time so workloads run with the correct GSA binding.
- Container promotion enforces Binary Authorization: `scripts/bootstrap-infra.sh` requires per-environment attestor IDs and writes them to GitHub environment secrets. Only images signed by Cosign and validated by these attestors may roll out.
- Cosign keyless signing in CI records SBOM attestations, producing a tamper-evident chain from build to deployment.

## Developer Notes

- The dev container installs Gitleaks (v8.18.2) and Semgrep at build time (see `.devcontainer/Dockerfile`).
- Run `gitleaks detect --config .gitleaks.toml --redact` or `semgrep ci --config semgrep.yml` locally to reproduce CI behaviour.
- Agents and contributors must follow `docs/AGENT_PROTOCOLS.md`, including the mandate to validate changes with unit and Playwright E2E tests before merge.

## Repository Hardening Automation

- Run `./scripts/github-hardening.sh` after provisioning the repository. The helper enables Advanced Security, Dependabot updates, secret scanning, applies strict branch protection, and enforces signed commits on the protected branch.
- Configure defaults (required status checks, environment reviewers, wait timers, signed commit enforcement) via `scripts/github-hardening.conf`. The script is idempotent, so re-run it whenever you add new workflow names or reviewer assignments.
- Deployment workflows refuse to proceed unless `scripts/kustomize/verify-overlay.sh` confirms that each environment overlay pins a valid `sha256` digest and Workload Identity annotation.
- Admission control via Gatekeeper: `./scripts/policy/apply-gatekeeper.sh` installs constraint templates that deny Pods lacking image digests and ServiceAccounts missing Workload Identity annotations. Apply them to every cluster and keep exemptions minimal.
- Nightly Terraform drift detection (`.github/workflows/infra-drift.yml`) re-plans staging infrastructure and fails on unexpected changes, forcing reconciliation before deploy windows.
- Agents operate exclusively in sandboxed copies created with `scripts/agent/create-project-workspace.sh`, keeping the platform repository read-only for humans.
- When an agent needs a shell, launch it through `scripts/agent/run-sandbox-container.sh` so it runs in a restricted container (read-only rootfs, dropped capabilities, optional network air gap).
