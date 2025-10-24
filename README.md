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

> **Supported platform:** Windows 11 (or Windows 10 22H2+) with administrator access. Native macOS and Linux automation are not provided; use WSL2 on Windows for the full experience.

Before you start, make sure you can provide the following:

- An elevated PowerShell session (Run as Administrator) on Windows.
- Outbound HTTPS access to `github.com`, `raw.githubusercontent.com`, `download.docker.com`, `aka.ms`, and `cursor.sh`.
- A GitHub account with **administrator** permissions on the target repository/organization (hardening enforces branch protection and environments).
- Access to the target Google Cloud project (owner/editor) if you plan to run the infrastructure bootstrap.
- A Google Cloud project **with billing enabled** (create one at <https://console.cloud.google.com/projectcreate> and attach a billing account before running the bootstrap).
- A GitHub repository/org where you have admin rights (fork this repo or create a new empty repository under your organization).

### Prepare required accounts (one time)

1. **Google Cloud project with billing**
   - Visit <https://console.cloud.google.com/projectcreate> and create a project (note the project ID).
   - Enable billing for the project (Billing → Link a billing account).
   - Optional: Pre-enable the "Cloud Resource Manager" API so the bootstrap can enumerate permissions.

2. **GitHub repository with admin permissions**
   - Fork `swb2019/ai-dev-platform` or create a new repository inside your organization.
   - Ensure your GitHub account has the "Admin" role on that repository (Settings → Collaborators & teams).
   - If using SSO/enforced security, authorize the repository so `gh auth login` can access it.

3. **CLI sign-in (optional but recommended before running the helper)**
   ```bash
   # Inside WSL (or any shell with gh installed)
   gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
   ```
   The Windows helper will prompt for authentication if you skip this step, but pre-authenticating can save time.

### Windows 11 quick start

1. **Install Git (one time):**

   ```powershell
   winget install --id Git.Git -e --source winget
   ```

   Restart PowerShell so `git` is on `PATH`. If winget is unavailable, download Git for Windows from <https://git-scm.com/download/win>.

2. **Clone or refresh the repository (idempotent):**

   ```powershell
   $workspace = 'C:\dev'
   $repoPath = Join-Path $workspace 'ai-dev-platform'
   New-Item -ItemType Directory -Force -Path $workspace | Out-Null
   Set-Location $workspace

   if (Test-Path (Join-Path $repoPath '.git')) {
     Set-Location $repoPath
     git fetch origin
     git checkout main
     git pull --ff-only origin main
   } elseif (Test-Path $repoPath) {
     throw "Path $repoPath already exists but is not a Git repository. Move or remove it, then rerun this block."
   } else {
     git clone https://github.com/swb2019/ai-dev-platform.git
     Set-Location $repoPath
   }
   ```

3. **(Optional) Sync your sandbox fork with upstream**

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\sync-sandbox.ps1
   ```

   This script authenticates the GitHub CLI if necessary, ensures your fork exists, mirrors the latest upstream commits, and sets the correct remotes.

4. **Run the automated bootstrap (elevated PowerShell):**

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1
   ```

   What the helper does:
   - Enables WSL2 features, installs/initializes Ubuntu, and sets it as default.
   - Installs **Cursor** via winget (or instructs you to install it manually if winget is unavailable).
   - Installs/updates Docker Desktop, enables WSL integration, and waits for the daemon.
   - Clones the repository inside WSL and executes `./scripts/setup-all.sh`.
   - Launches `gh auth login --web` inside both Windows and WSL contexts (if needed), refreshes the token scopes (`repo`, `workflow`, `admin:org`), and verifies the signed-in user has admin rights on the repository. The helper relays the OAuth URL to your Windows browser automatically; if it does not open, copy the printed URL manually and paste it into your browser.
   - Automatically creates the GitHub repository (via `gh repo create`) if it does not yet exist or is empty, then continues.
   - Offers to configure Google Cloud (interactive `gcloud auth login`, `gcloud auth application-default login`, and `./scripts/bootstrap-infra.sh`) and to update GitHub environments automatically. Browser windows open on Windows; if the browser is blocked, copy the displayed URL manually. When the script reaches the Infisical step it first asks for an existing `INFISICAL_TOKEN` and only generates one (with a cost warning) if you explicitly opt in.
   - Offers to launch Cursor at the end so you can immediately sign into Codex and Claude Code.

   You can supply overrides such as `-RepoSlug your-user/ai-dev-platform`, `-Branch feature`, `-WslUserName devuser`, or `-DockerInstallerPath C:\Installers\DockerDesktopInstaller.exe`. When prompted for optional tokens (`GH_TOKEN`, `INFISICAL_TOKEN`), press <kbd>Enter</kbd> to skip unless you have a PAT/Infisical secret ready. Re-running the helper is safe; it resumes from checkpoints stored under `~/.cache/ai-dev-platform/setup-state`.

5. **Sign into Cursor assistants (one time):**
   - Launch Cursor (installed to `%LOCALAPPDATA%\Programs\Cursor\Cursor.exe`).
   - Sign into GitHub when prompted.
   - Press `Ctrl+Shift+P` → “Codex: Sign In” and complete the browser flow (requires accepting the GitHub OAuth prompt).
   - Repeat for “Claude Code: Sign In” (Claude Code also needs GitHub OAuth approval).

6. **Verify the WSL workspace:**
   ```bash
   cd ~/ai-dev-platform
   pnpm --filter @ai-dev-platform/web dev
   ```
   The setup wrapper already ran lint, type-check, and Jest/Playwright smoke tests. Rerun `./scripts/setup-all.sh` anytime; add `RESET_SETUP_STATE=1 ./scripts/setup-all.sh` to force every step.

> **Heads-up:** If the bootstrap reports “Repository hardening still requires manual completion,” follow the instructions in `~/ai-dev-platform/tmp/github-hardening.pending` (usually finishing `gh auth login`) and rerun `./scripts/github-hardening.sh`.

7. **If you skipped the guided cloud setup, run the following inside WSL to configure deployments:**
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ./scripts/bootstrap-infra.sh
   ./scripts/configure-github-env.sh staging
   ./scripts/configure-github-env.sh prod
   ```
   When prompted, supply your GCP project ID, region, Terraform state bucket name, and confirm the GitHub environments to update. Set `INFISICAL_TOKEN` before running `configure-github-env.sh` if you rely on Infisical-managed secrets (optional for OSS usage).

### macOS & Linux quick start

1. Install prerequisites: Node.js 20.x, pnpm 9 (`corepack prepare pnpm@9.12.0 --activate`), Docker Engine/Desktop (`docker info` must pass), `gcloud`, Terraform, GitHub CLI (`gh auth login`), and Playwright system deps (`pnpm --filter @ai-dev-platform/web exec playwright install --with-deps`).
2. Clone the repository:
   ```bash
   git clone https://github.com/swb2019/ai-dev-platform.git
   cd ai-dev-platform
   ```
3. Run the consolidated setup:
   ```bash
   ./scripts/setup-all.sh
   ```
   Stay in the prompt when `gh auth login --web` launches; the script resumes after the browser flow completes.
4. Install Cursor from <https://cursor.sh/>, sign into GitHub, then sign into Codex and Claude Code via the command palette.
5. Start developing with `pnpm --filter @ai-dev-platform/web dev`.

### Troubleshooting & recovery

- **Resume setup:** rerun `./scripts/setup-all.sh`; it reads progress from `tmp/setup-all.state` (or `~/.cache/ai-dev-platform/setup-state` on WSL).
- **Force a clean run:** `RESET_SETUP_STATE=1 ./scripts/setup-all.sh`.
- **Inspect post-check failures:** review `tmp/postcheck-*.log`.
- **Replay GitHub hardening:** `./scripts/github-hardening.sh` (the script relaunches `gh auth login --web` until successful).
- **Provide GitHub admin rights:** the account used during `gh auth login` must have admin permissions on `${OWNER}/${REPO}`; otherwise the hardening step will pause with instructions.
- **Docker not ready:** On Windows, ensure Docker Desktop is running with WSL integration enabled; rerun the bootstrap helper.
- **Cursor missing:** Install it manually from <https://cursor.sh/download> and rerun the helper or `./scripts/update-editor-extensions.sh`.

### Additional scripts

1. **Bootstrap infrastructure (optional standalone)**
   ```bash
   ./scripts/bootstrap-infra.sh
   ```
   Initializes Terraform backends, enables required GCP services, configures Workload Identity Federation, and offers applies per environment.
2. **Configure GitHub environments**
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

## Immutability Enforcement

- Deployment workflows now call `scripts/kustomize/verify-overlay.sh` after patching the staging and production overlays. The helper fails fast if any placeholder image values or unsigned digests slip through:
  ```bash
  bash scripts/kustomize/verify-overlay.sh deploy/k8s/overlays/staging ghcr.io/example/web
  ```
  Use it locally before submitting a release to guarantee the overlay references a `sha256` digest and a real Workload Identity binding.
- Gatekeeper policies under `deploy/policies/gatekeeper/` deny pods that omit image digests and block ServiceAccounts lacking Workload Identity annotations. Apply them per cluster with:
  ```bash
  ./scripts/policy/apply-gatekeeper.sh
  ```
- Repository hardening is automated by `scripts/github-hardening.sh`, which enables Advanced Security, configures environment reviewers, applies strict branch protection, and now enforces signed commits on `main`. Adjust defaults in `scripts/github-hardening.conf`, then run:
  ```bash
  gh auth login --scopes admin:repo_hook,repo
  ./scripts/github-hardening.sh
  ```
  The script is idempotent and safe to re-run after adding new required checks or reviewers.
- Scheduled drift detection (`.github/workflows/infra-drift.yml`) reruns Terraform plans with a detailed exit code. If drift is detected the pipeline fails and uploads the rendered plan artifact so platform engineers can reconcile state before it grows.
- Agents should never touch the platform repository directly. Generate isolated workspaces with:
  ```bash
  scripts/agent/create-project-workspace.sh --name demo-project
  ```
  Point Codex/Claude at the sandbox, review their output manually, and promote only accepted changes back into the platform through signed commits.
- Launch agents inside the hardened container wrapper to keep them away from host secrets:
  ```bash
  scripts/agent/run-sandbox-container.sh --workspace ../project-workspaces/demo-project
  ```
  This uses Docker with `--read-only`, dropped capabilities, memory/CPU limits, and disabled networking by default; enable connectivity only when supervised.

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
- [Hardening Runbook](docs/HARDENING_RUNBOOK.md)
- [Agent Sandbox Workflow](docs/AGENT_SANDBOX.md)
- [Agent Execution Specification](docs/agents/EXECUTION_SPEC.md)
- [Agent Decision Playbook](docs/agents/DECISION_PLAYBOOK.md)
- [Agent Risk Register](docs/agents/RISK_REGISTER.md)
- [Agent Prompt Template](docs/agents/PROMPT_TEMPLATE.md)
- [Agent Quality Checklist](docs/agents/QUALITY_CHECKLIST.md)
- [Dedicated Repository Checks](docs/agents/DEDICATED_REPO_CHECKS.md)
- [Remote Automation Setup](docs/REMOTE_AUTOMATION_SETUP.md)

Refer to these guides for environment-specific configuration, operational runbooks, and security guardrails.

## Resetting / Uninstalling

To wipe generated state (caches, node_modules, extension locks) run:

```bash
./scripts/uninstall.sh --force --include-home
```

Add `--destroy-cloud` to tear down Terraform-managed infrastructure (ensure you have credentials and intend to remove cloud resources).
