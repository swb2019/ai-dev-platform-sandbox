# AI Dev Platform

**A secure, production-ready foundation for deploying AI-oriented applications to Google Kubernetes Engine (GKE) Autopilot.**

The AI Dev Platform is a comprehensive monorepo that bundles a modern Next.js 14 application, shared TypeScript tooling, Terraform-based infrastructure, and automated CI/CD pipelines. It is designed with a security-first approach, integrating supply-chain scanning, binary authorization, and end-to-end validation to ensure robust and reliable deployments.

## Key Features

- **Modern web stack:** Next.js 14 (App Router), React 18, and Tailwind CSS v4.
- **GKE Autopilot delivery:** Automated Kubernetes deployments via Kustomize and Gateway API routing.
- **Infrastructure as Code:** GCP infrastructure managed entirely by Terraform (GKE, networking, Workload Identity Federation, Artifact Registry).
- **Secure CI/CD:** GitHub Actions workflows authenticate to GCP via Workload Identity Federation for keyless operations.
- **Supply-chain security:** Integrated scanning (Trivy, Grype), SBOM generation (Syft), and keyless signing (Cosign).
- **Binary Authorization:** Enforced in GKE so only signed and attested images are admitted.
- **Comprehensive testing:** Jest + Testing Library unit tests and Playwright E2E tests wired into the delivery pipeline.
- **Monorepo ergonomics:** PNPM workspaces and Turbo coordinate builds, tests, and shared tooling.
- **Security guardrails:** Gitleaks, Semgrep, CodeQL, and centralized ESLint rules (security + SonarJS) run locally and in CI.

## Architecture Overview

This platform leverages GKE Autopilot for managed Kubernetes, using the Gateway API for external traffic management. Infrastructure is composed with Terraform modules and applied per environment (staging and production). Deployments rely on Kustomize overlays that inject immutable image digests and Workload Identity bindings. GitHub Actions authenticates through Workload Identity Federation (WIF) to push signed images to Artifact Registry and apply manifests to GKE, where Binary Authorization enforces attestation policies.

<img src="docs/diagrams/architecture-overview.svg" alt="Architecture overview diagram" width="800">

## Repository Map

The codebase is organized as a PNPM workspace managed by Turbo.

```
.
├── apps/
│   └── web/                  # Next.js 14 App Router application (Tailwind v4, Jest, Playwright)
├── deploy/
│   └── k8s/                  # Kustomize manifests
│       ├── base/             # Shared Kubernetes resources (Deployment, Service, Gateway, HTTPRoute)
│       └── overlays/         # Environment-specific patches (staging, production)
├── docs/                     # Architecture, security, onboarding, runbooks
├── infra/
│   └── terraform/            # Infrastructure as Code
│       ├── envs/             # Environment configurations (staging, production)
│       └── modules/          # Reusable modules (GKE, network, services, WIF)
├── packages/
│   ├── eslint-config-custom/ # Centralized ESLint rules (TypeScript, security, SonarJS)
│   └── tsconfig/             # Shared TypeScript presets
├── scripts/                  # Operational helpers (onboarding, infra bootstrap, CI/CD helpers, supply chain tooling)
├── .github/
│   └── workflows/            # CI/CD pipelines (CI, deploy, Terraform, CodeQL, security validation)
└── turbo.json                # Turbo configuration
```

## Technology Stack

- **Frontend:** Next.js 14 (App Router), React 18, TypeScript, Tailwind CSS v4.
- **Testing:** Jest, React Testing Library, Playwright.
- **Tooling:** PNPM workspaces, Turbo, ESLint, Prettier, Husky, Commitlint.
- **Infrastructure:** Terraform, GKE Autopilot, Artifact Registry, VPC networking, Workload Identity Federation.
- **DevOps:** Kustomize, Gateway API, Docker (distroless runtime).
- **Security:** Cosign, Syft, Grype, Trivy, Gitleaks, Semgrep, CodeQL, GCP Binary Authorization.

## Getting Started

### Prerequisites

Ensure the following tools are installed and authenticated:

1. **Node.js 20.x** – enable Corepack and activate pnpm 9:
   ```bash
   corepack enable && corepack prepare pnpm@9.12.0 --activate
   ```
2. **Docker** – required for local container builds and scanning.
3. **CLIs** – Google Cloud CLI (`gcloud`), Terraform CLI, and GitHub CLI (`gh`) with access to the target project.
4. **Playwright dependencies** – install browser dependencies once locally:
   ```bash
   pnpm --filter @ai-dev-platform/web exec playwright install --with-deps
   ```

### Setup

The provided scripts streamline the initial setup:

1. **One-shot setup**
   ```bash
   ./scripts/setup-all.sh
   ```
   Runs onboarding, infrastructure bootstrap, repository hardening, and editor extension management.
2. **Bootstrap infrastructure (optional standalone)**
   ```bash
   ./scripts/bootstrap-infra.sh
   ```
   Initializes Terraform backends, enables required GCP services, configures Workload Identity Federation, and offers applies per environment.
3. **Configure GitHub environments**
   ```bash
   ./scripts/configure-github-env.sh staging
   ./scripts/configure-github-env.sh prod
   ```
   Populates GitHub environment secrets/variables (e.g., WIF provider, Artifact Registry, GKE cluster metadata) from Terraform outputs.

### Local Development

Use pnpm filters to target the web application:

- **Run the web app**
  ```bash
  pnpm --filter @ai-dev-platform/web dev
  ```
- **Linting and type checking**
  ```bash
  pnpm lint
  pnpm type-check
  ```
- **Testing**
  ```bash
  # Unit tests
  pnpm --filter @ai-dev-platform/web test
  # E2E tests (Playwright starts a dev server when E2E_TARGET_URL is unset)
  pnpm --filter @ai-dev-platform/web test:e2e
  ```
- **Build the application**
  ```bash
  pnpm --filter @ai-dev-platform/web build
  ```

## CI/CD Pipeline

GitHub Actions enforces quality and security before any deployment.

1. **Continuous Integration (`.github/workflows/ci.yml`)**
   - Security scans: Gitleaks and Semgrep.
   - Quality gates: `pnpm install --frozen-lockfile`, lint, type-check, unit tests, build, format check.
   - Supply chain: build container, scan (Trivy/Grype), generate SBOM (Syft), sign (Cosign).
2. **Deployment (`deploy-staging.yml`, `deploy-production.yml`)**
   - Authenticates to GCP via Workload Identity Federation.
   - Rebuilds and signs the image, pushes to Artifact Registry, resolves the immutable digest.
   - Patches Kustomize overlays with the digest and Workload Identity annotation, applies manifests to GKE, waits for rollout.
   - Runs Playwright E2E tests against the live Gateway endpoint (staging always; production workflows can be extended similarly).

<img src="docs/diagrams/cicd-pipeline.svg" alt="CI/CD pipeline diagram" width="900">

## Supply Chain Security

The platform applies rigorous supply-chain controls to preserve artifact integrity:

1. **Scanning:** Trivy and Grype run during CI and fail the pipeline on High/Critical (Trivy) or High (Grype) findings.
2. **SBOM generation:** Syft produces CycloneDX SBOMs that are uploaded as workflow artifacts.
3. **Keyless signing:** Cosign uses GitHub Actions OIDC (via WIF) to sign images and attest the SBOM with no long-lived keys.
4. **Binary Authorization:** GKE Autopilot clusters enforce Binary Authorization, allowing only signed and attested images to run.
5. **Immutable images:** Deployment workflows resolve tags to immutable digests and patch Kustomize overlays before applying manifests.

Developers can run the same steps locally with:

```bash
./scripts/container/supply-chain.sh build
./scripts/container/supply-chain.sh scan
./scripts/container/supply-chain.sh sbom
./scripts/container/supply-chain.sh sign
```

## Development Workflow

This project enforces a consistent workflow to maintain quality, security, and reproducibility:

1. **Branching:** Create feature branches from `main`; never commit directly to protected branches.
2. **Commits:** Follow Conventional Commits (`commitlint` enforces format).
3. **Pre-commit hooks:** Husky runs `gitleaks protect --staged` and `lint-staged` (ESLint + Prettier) on staged files.
4. **Pre-push hooks:** Verify editor extension lock consistency and capture git sync status.
5. **Pull requests:** Use the helper script to validate, push, and open PRs with auto-merge enabled:
   ```bash
   ./scripts/push-pr.sh
   ```
6. **Monitor merges:** Track PR status until merge (or failure) to ensure required checks pass:
   ```bash
   ./scripts/monitor-pr.sh
   ```
7. **Editor extensions:** Keep AI assistant extensions aligned across contributors:
   ```bash
   ./scripts/update-editor-extensions.sh
   ./scripts/verify-editor-extensions.sh --strict
   ```
   Commit changes to `config/editor-extensions.lock.json` whenever versions differ.

## Documentation

Detailed references are available in the `docs/` directory:

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Security Guardrails](docs/SECURITY.md)
- [Supply-Chain Hardening](docs/SUPPLY_CHAIN.md)
- [Infrastructure Automation](docs/INFRASTRUCTURE.md)
- [Deployment Guide](docs/DEPLOYMENT.md)
- [Agent Protocols](docs/AGENT_PROTOCOLS.md)
- [Onboarding Guide](docs/ONBOARDING.md)
- [Release Runbook](docs/RELEASE_RUNBOOK.md)

Refer to these guides for environment-specific configuration, operational runbooks, and security guardrails.
