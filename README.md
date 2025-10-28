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
   - Installs **Cursor** via winget (and, if winget cannot install it, fetches and caches the newest signed Windows installer from Cursor's GitHub releases—honoring proxy env vars—or respects `-CursorInstallerPath` / `CURSOR_INSTALLER_PATH` overrides).
   - Installs/updates Docker Desktop, enables WSL integration, and waits for the daemon.
   - Clones the repository inside WSL and executes `./scripts/setup-all.sh`.
   - Launches `gh auth login --web` inside both Windows and WSL contexts (if needed), refreshes the token scopes (`repo`, `workflow`, `admin:org`), and verifies the signed-in user has admin rights on the repository. The helper relays the OAuth URL to your Windows browser automatically; if it does not open, copy the printed URL manually and paste it into your browser.
   - Automatically creates the GitHub repository (via `gh repo create`) if it does not yet exist or is empty, then continues.
   - Offers to configure Google Cloud (interactive `gcloud auth login`, `gcloud auth application-default login`, and `./scripts/bootstrap-infra.sh`) and to update GitHub environments automatically. Browser windows open on Windows; if the browser is blocked, copy the displayed URL manually. When the script reaches the Infisical step it first asks for an existing `INFISICAL_TOKEN` and only generates one (with a cost warning) if you explicitly opt in.
   - When Terraform runs, the helper auto-approves the plan (`AUTO_APPROVE=1`, `TF_IN_AUTOMATION=1`), so no manual `yes` confirmation is required.
   - Terraform applies are retried automatically (default three attempts, configurable via `TERRAFORM_MAX_RETRIES`) to ride out transient network hiccups.
   - Ensures the Cursor Codex and Claude Code extensions are installed, falling back to cached VSIX packages if the marketplace or CLI is unavailable.
   - Reminds you to launch Cursor from a standard (non-admin) session at the end so you can sign into Codex and Claude Code without inheriting elevated privileges.

   You can supply overrides such as `-RepoSlug your-user/ai-dev-platform`, `-Branch feature`, `-WslUserName devuser`, `-DockerInstallerPath C:\Installers\DockerDesktopInstaller.exe`, or `-CursorInstallerPath C:\Installers\CursorSetup.exe`. The Cursor override accepts a single installer, a directory that contains `CursorSetup*.exe`, or a pre-downloaded `.zip` archive. When prompted for optional tokens (`GH_TOKEN`, `INFISICAL_TOKEN`), press <kbd>Enter</kbd> to skip unless you have a PAT/Infisical secret ready. Re-running the helper is safe; it resumes from checkpoints stored under `~/.cache/ai-dev-platform/setup-state`.

5. **Sign into Cursor assistants (one time):**
   - Launch Cursor from the Start menu (installed to `%LOCALAPPDATA%\Programs\Cursor\Cursor.exe`) after closing the elevated bootstrap PowerShell window so it runs with normal user privileges.
   - Sign into GitHub when prompted.
   - Press `Ctrl+Shift+P` → “Codex: Sign In” and complete the browser flow (requires accepting the GitHub OAuth prompt).
   - Repeat for “Claude Code: Sign In” (Claude Code also needs GitHub OAuth approval).
   - The bootstrap attempts to pre-install the Codex and Claude Code extensions via the Cursor CLI. If either extension is missing, open a regular PowerShell window and run:
     ```powershell
     & "$env:LOCALAPPDATA\Programs\Cursor\resources\app\bin\cursor.cmd" --install-extension openai.chatgpt --force
     & "$env:LOCALAPPDATA\Programs\Cursor\resources\app\bin\cursor.cmd" --install-extension anthropic.claude-code --force
     ```

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
- **Cursor missing:** Re-run the Windows bootstrap; it caches the latest signed installer from Cursor's GitHub releases (respecting proxy env vars) and logs diagnostics to `%ProgramData%\ai-dev-platform\cursor-install.log` (or `%LOCALAPPDATA%\ai-dev-platform\cursor-install.log`). You can also provide `-CursorInstallerPath C:\Installers\CursorSetup.exe` (or set `CURSOR_INSTALLER_PATH`), point it at a directory that contains the installer, or hand it a `.zip` with `CursorSetup*.exe` and rerun. Manual installation from <https://cursor.sh/download> before re-running the helper or `./scripts/update-editor-extensions.sh` also works when automation is intentionally disabled.
- **Terraform / deploy workflows skipped:** The GitHub Actions guards require the following repository secrets to be populated: `TERRAFORM_SERVICE_ACCOUNT`, `WORKLOAD_IDENTITY_PROVIDER`, `GCP_PROJECT_ID`, `GCP_REGION`, `RUNTIME_KSA_NAMESPACE`, `RUNTIME_KSA_NAME`, `BA_ATTESTORS`, plus environment-specific secrets (`STAGING_*` and `PRODUCTION_*` for image registries, GKE, and Workload Identity) and feature toggles (`vars.STAGING_INFRA_ENABLED`, `vars.PRODUCTION_INFRA_ENABLED`, `vars.STAGING_DEPLOY_ENABLED`, `vars.PRODUCTION_DEPLOY_ENABLED`). Without them the workflows auto-skip and emit a notice instead of failing.

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

On Windows, always use the PowerShell wrapper `Reset-AiDevPlatform.ps1`. Run it from an elevated PowerShell session at the repository root. The script coordinates the WSL uninstall, removes host tooling (Cursor, Docker Desktop, cached data), and deletes the checkout directory after the run completes.

- Inspect actions without deleting anything:
  ```powershell
  .\Reset-AiDevPlatform.ps1 -DryRun
  ```
- Perform a standard reset that retains Terraform-managed cloud resources:
  ```powershell
  .\Reset-AiDevPlatform.ps1
  ```

Need to remove absolutely everything the setup scripts created—including Terraform infrastructure? Run the automated teardown snippet below from an elevated PowerShell session. It auto-detects (or downloads) the repository (honour `$env:AI_DEV_PLATFORM_REPO` if you keep it somewhere unusual), enables the required WSL features when they are missing, fetches a known-good Terraform binary if one is not already available, executes the WSL uninstall with `--destroy-cloud`, relaunches the Windows cleanup helper, repeatedly stops lingering Docker/Cursor processes, unregisters WSL distributions, clears related environment variables, performs winget **and** fallback MSI removals, and verifies that nothing remains. Whenever credentials or approvals are required, the script launches the appropriate sign-in flow and guides you interactively; it only aborts once every automated recovery option has been exhausted, so you should treat the reset as complete only after it prints the green confirmation at the end. It also detects when the current checkout points at a GitHub fork (origin != upstream) and, after confirming with you, deletes that fork while refusing to touch the upstream repository.

```powershell
# DANGER: This permanently deletes local tooling, repo caches, and Terraform-managed infrastructure.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this teardown from an elevated PowerShell session."
    }
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($existing in $List) {
        if ($existing -ieq $Value) { return }
    }
    $List.Add($Value)
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return
    }
    foreach ($existing in $List) {
        if ($existing -ieq $full) { return }
    }
    $List.Add($full)
}

function Test-IsRepoRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        return $false
    }
    $resetScript = Join-Path $resolved 'Reset-AiDevPlatform.ps1'
    $uninstallScript = Join-Path $resolved 'scripts\uninstall.sh'
    return (Test-Path -LiteralPath $resetScript) -and (Test-Path -LiteralPath $uninstallScript)
}

function Convert-WindowsPathToWsl {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ($resolved -match '^[A-Za-z]:\\') {
        $drive = $resolved.Substring(0,1).ToLowerInvariant()
        $rest  = $resolved.Substring(2).TrimStart('\\') -replace '\\','/'
        return "/mnt/$drive/$rest"
    }
    return ($resolved -replace '\\','/')
}

function Escape-WslSingleQuote {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return ($Text -replace "'", "'\\''")
}

function Test-WslOperational {
    try {
        & wsl.exe -l -q 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-WslDistributions {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    try {
        return (& wsl.exe -l -q 2>$null) | ForEach-Object { ($_ -replace "`0","").Trim() } | Where-Object { $_ }
    } catch {
        return @()
    }
}

function Ensure-WslReady {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $status = [ordered]@{ Ready = $false; PendingReboot = $false }
    $wslExists = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
    if ($wslExists -and (Test-WslOperational)) {
        $status.Ready = $true
        return $status
    }
    $Notes.Add("WSL is not fully available; enabling Windows Subsystem for Linux and Virtual Machine Platform features.")
    $features = @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
    foreach ($feature in $features) {
        $args = "/online","/enable-feature","/featurename:$feature","/all","/norestart"
        $output = & dism.exe $args 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 3010) {
            $status.PendingReboot = $true
        } elseif ($exitCode -ne 0) {
            $Issues.Add("dism.exe failed to enable feature '$feature' (exit $exitCode). Output: $($output -join ' ')")
            return $status
        }
    }
    if ($wslExists) {
        try {
            $installOutput = & wsl.exe --install -d Ubuntu --no-launch 2>&1
            $exit = $LASTEXITCODE
            if ($exit -eq 0 -and ($installOutput -match 'restart' -or $installOutput -match 'Reboot')) {
                $status.PendingReboot = $true
            }
        } catch {
            $Notes.Add("Attempt to initialize WSL returned: $($_.Exception.Message)")
        }
    }
    if (Test-WslOperational) {
        $status.Ready = $true
    } elseif (-not $status.PendingReboot) {
        $Issues.Add("WSL is still unavailable after enabling features. Install WSL manually and rerun the teardown.")
    }
    return $status
}

function Acquire-AiDevRepo {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($envName in 'AI_DEV_PLATFORM_REPO','AI_DEV_PLATFORM_PATH','AI_DEV_PLATFORM_ROOT') {
        $value = [Environment]::GetEnvironmentVariable($envName,'Process')
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($envName,'User') }
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($envName,'Machine') }
        Add-UniqueString -List $candidates -Value $value
    }
    if ($MyInvocation.MyCommand.Path) {
        Add-UniqueString -List $candidates -Value (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    try {
        $pwdCandidate = (Get-Location).ProviderPath
        Add-UniqueString -List $candidates -Value $pwdCandidate
        $gitRoot = (& git -C $pwdCandidate rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            Add-UniqueString -List $candidates -Value ($gitRoot.Trim())
        }
    } catch {}
    $userProfile = $env:UserProfile
    foreach ($path in @(
        "$userProfile\ai-dev-platform",
        "$userProfile\dev\ai-dev-platform",
        "C:\dev\ai-dev-platform"
    )) {
        Add-UniqueString -List $candidates -Value $path
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        try {
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root 'ai-dev-platform')
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root 'dev\ai-dev-platform')
            Add-UniqueString -List $candidates -Value (Join-Path $drive.Root "Users\$env:USERNAME\ai-dev-platform")
        } catch {}
    }
    foreach ($candidate in $candidates) {
        if (Test-IsRepoRoot $candidate) {
            $resolved = (Resolve-Path -LiteralPath $candidate).ProviderPath
            return [ordered]@{ Path = $resolved; Temporary = $false }
        }
    }
    $Notes.Add("Local repository not found. Downloading a fresh archive of ai-dev-platform.")
    $downloadRoot = Join-Path $env:ProgramData "ai-dev-platform\teardown-cache"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    $archivePath = Join-Path $downloadRoot "ai-dev-platform-main.zip"
    try {
        $currentProtocols = [Net.ServicePointManager]::SecurityProtocol
        if (($currentProtocols -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {}
    $repoUrl = "https://github.com/swb2019/ai-dev-platform/archive/refs/heads/main.zip"
    try {
        Invoke-WebRequest -Uri $repoUrl -OutFile $archivePath -UseBasicParsing
    } catch {
        $Issues.Add("Failed to download repository archive from $repoUrl: $($_.Exception.Message)")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    try {
        Expand-Archive -Path $archivePath -DestinationPath $downloadRoot -Force
    } catch {
        $Issues.Add("Failed to extract repository archive ($archivePath): $($_.Exception.Message)")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    $extracted = Get-ChildItem -Path $downloadRoot -Directory | Where-Object { Test-IsRepoRoot $_.FullName } | Select-Object -First 1
    if (-not $extracted) {
        $Issues.Add("Repository archive extracted but the expected layout was not found under $downloadRoot.")
        return [ordered]@{ Path = $null; Temporary = $false }
    }
    return [ordered]@{ Path = (Resolve-Path -LiteralPath $extracted.FullName).ProviderPath; Temporary = $true }
}

function Ensure-TerraformAvailable {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )
    $command = Get-Command terraform.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $Notes.Add("Terraform CLI not found; downloading Terraform 1.6.6 for Windows.")
    $version = "1.6.6"
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows_arm64' } else { 'windows_amd64' }
    $downloadRoot = Join-Path $env:ProgramData "ai-dev-platform\terraform"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    $archivePath = Join-Path $downloadRoot "terraform_$version.zip"
    $uri = "https://releases.hashicorp.com/terraform/$version/terraform_${version}_${platform}.zip"
    try {
        Invoke-WebRequest -Uri $uri -OutFile $archivePath -UseBasicParsing
    } catch {
        $Issues.Add("Unable to download Terraform from $uri: $($_.Exception.Message)")
        return $null
    }
    try {
        Expand-Archive -Path $archivePath -DestinationPath $downloadRoot -Force
    } catch {
        $Issues.Add("Unable to extract Terraform archive ($archivePath): $($_.Exception.Message)")
        return $null
    }
    $terraformExe = Join-Path $downloadRoot "terraform.exe"
    if (-not (Test-Path -LiteralPath $terraformExe)) {
        $Issues.Add("Terraform executable not found after extraction at $terraformExe.")
        return $null
    }
    if ($env:PATH -notlike "*$downloadRoot*") {
        $env:PATH = "$downloadRoot;$env:PATH"
    }
    return $terraformExe
}


function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-CredentialReadiness {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )

    if (Test-CommandAvailable 'gcloud') {
        $gcloudAccountOk = $false
        try {
            $accounts = (& gcloud auth list --format=value(account) 2>$null)
            $gcloudAccountOk = [bool]$accounts
        } catch {
            $Issues.Add("Unable to query gcloud accounts: $($_.Exception.Message)")
            $accounts = @()
        }
        if (-not $gcloudAccountOk) {
            Write-Host "Google Cloud CLI is installed but no authenticated user is configured." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gcloud auth login' now, or type 'skip' to leave it unset"
            $launchLogin = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchLogin = $false
            }
            if ($launchLogin) {
                try {
                    & gcloud auth login --brief
                } catch {
                    $Issues.Add("gcloud auth login failed: $($_.Exception.Message)")
                }
                try {
                    $accounts = (& gcloud auth list --format=value(account) 2>$null)
                    $gcloudAccountOk = [bool]$accounts
                } catch {
                    $gcloudAccountOk = $false
                }
            }
        }
        if (-not $gcloudAccountOk) {
            $Issues.Add("Google Cloud CLI lacks an authenticated user. Run 'gcloud auth login' before rerunning the teardown.")
        }

        $adcOk = $false
        try {
            & gcloud auth application-default print-access-token 2>$null
            $adcOk = ($LASTEXITCODE -eq 0)
        } catch {
            $adcOk = $false
        }
        if (-not $adcOk) {
            Write-Host "Google Application Default Credentials are missing." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gcloud auth application-default login', or type 'skip' to leave it unset"
            $launchAdc = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchAdc = $false
            }
            if ($launchAdc) {
                try {
                    & gcloud auth application-default login
                } catch {
                    $Issues.Add("gcloud auth application-default login failed: $($_.Exception.Message)")
                }
                try {
                    & gcloud auth application-default print-access-token 2>$null
                    $adcOk = ($LASTEXITCODE -eq 0)
                } catch {
                    $adcOk = $false
                }
            }
        }
        if (-not $adcOk) {
            $Issues.Add("Application Default Credentials are still unavailable. Run 'gcloud auth application-default login' before rerunning the teardown.")
        }
    } else {
        $Issues.Add("gcloud CLI not found on PATH; install Google Cloud SDK or provide credentials before rerunning the teardown.")
    }

    if (Test-CommandAvailable 'gh') {
        $ghOk = $false
        try {
            & gh auth status --hostname github.com 2>&1 | Out-Null
            $ghOk = ($LASTEXITCODE -eq 0)
        } catch {
            $ghOk = $false
        }
        if (-not $ghOk) {
            Write-Host "GitHub CLI is not authenticated for github.com." -ForegroundColor Yellow
            $answer = Read-Host "Press Enter to launch 'gh auth login --hostname github.com --web', or type 'skip' to continue without GitHub access"
            $launchGh = $true
            if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('skip','s')) {
                $launchGh = $false
            }
            if ($launchGh) {
                try {
                    & gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
                } catch {
                    $Issues.Add("gh auth login failed: $($_.Exception.Message)")
                }
                try {
                    & gh auth status --hostname github.com 2>&1 | Out-Null
                    $ghOk = ($LASTEXITCODE -eq 0)
                } catch {
                    $ghOk = $false
                }
            }
        }
        if (-not $ghOk) {
            $Issues.Add("GitHub CLI authentication required. Run 'gh auth login --hostname github.com' before rerunning the teardown.")
        }
    } else {
        $Notes.Add("GitHub CLI not detected; skipping GitHub verification.")
    }
}



function Convert-SecureStringToPlainText {
    param([System.Security.SecureString]$SecureString)
    if (-not $SecureString) { return "" }
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Ensure-InfisicalToken {
    param(
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )

    $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','Process')
    if (-not $existing) {
        $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','User')
    }
    if (-not $existing) {
        $existing = [Environment]::GetEnvironmentVariable('INFISICAL_TOKEN','Machine')
    }

    if ([string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Infisical token not detected." -ForegroundColor Yellow
        Write-Host "If your Terraform state or bootstrap scripts rely on Infisical-managed secrets, paste your INFISICAL_TOKEN now." -ForegroundColor Yellow
        Write-Host "Press Enter to paste the token; type 'skip' to continue without one." -ForegroundColor Yellow
        $response = Read-Host "INFISICAL_TOKEN"
        if ([string]::IsNullOrWhiteSpace($response)) {
            $secure = Read-Host "Paste INFISICAL_TOKEN" -AsSecureString
            $plain = Convert-SecureStringToPlainText $secure
        } elseif ($response.Trim().ToLowerInvariant() -in @('skip','s')) {
            $plain = ""
        } else {
            $plain = $response
        }
        if ([string]::IsNullOrWhiteSpace($plain)) {
            $Notes.Add("Proceeding without INFISICAL_TOKEN. Ensure Terraform destroy does not require Infisical secrets.")
        } else {
            [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN',$plain,[EnvironmentVariableTarget]::Process)
            $Notes.Add("INFISICAL_TOKEN loaded into the current session for teardown.")
        }
    } else {
        [Environment]::SetEnvironmentVariable('INFISICAL_TOKEN',$existing,[EnvironmentVariableTarget]::Process)
        $Notes.Add("INFISICAL_TOKEN detected and loaded for teardown.")
    }
}


function Get-GitRemoteSlug {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Remote = 'origin'
    )
    if (-not (Test-CommandAvailable 'git')) { return "" }
    try {
        $url = & git -C $RepoPath remote get-url $Remote 2>$null
    } catch {
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($url)) { return "" }
    $url = $url.Trim()
    $match = [Regex]::Match($url, 'github.com[:/](.+?)(\.git)?$')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Invoke-GitHubForkDeletion {
    param(
        [string]$OriginSlug,
        [string]$UpstreamSlug,
        [System.Collections.Generic.List[string]]$Notes,
        [System.Collections.Generic.List[string]]$Issues
    )

    if ([string]::IsNullOrWhiteSpace($OriginSlug)) {
        $Notes.Add("Origin remote not detected; skipping GitHub repository deletion.")
        return
    }
    if ([string]::IsNullOrWhiteSpace($UpstreamSlug)) {
        $UpstreamSlug = 'swb2019/ai-dev-platform'
    }
    if ($OriginSlug -eq $UpstreamSlug) {
        $Notes.Add("Origin remote matches upstream ($OriginSlug); GitHub repository deletion skipped.")
        return
    }
    if (-not (Test-CommandAvailable 'gh')) {
        $Notes.Add("GitHub CLI not available; delete '$OriginSlug' manually if desired.")
        return
    }

    Write-Host "";
    Write-Host "Detected GitHub repository '$OriginSlug' linked to this checkout." -ForegroundColor Yellow
    Write-Host "This is different from upstream ($UpstreamSlug)." -ForegroundColor Yellow
    $answer = Read-Host "Delete GitHub repository '$OriginSlug'? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'y' }
    if ($answer.Trim().ToLowerInvariant() -notin @('y','yes')) {
        $Notes.Add("Skipped deletion of GitHub repository '$OriginSlug'.")
        return
    }

    try {
        & gh repo view $OriginSlug --json name 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $Notes.Add("GitHub repository '$OriginSlug' not found or inaccessible; skipping deletion.")
            return
        }
    } catch {
        $Issues.Add("Unable to verify GitHub repository '$OriginSlug': $($_.Exception.Message)")
        return
    }

    try {
        & gh repo delete $OriginSlug --yes
        if ($LASTEXITCODE -eq 0) {
            $Notes.Add("Deleted GitHub repository '$OriginSlug'.")
        } else {
            $Issues.Add("gh repo delete '$OriginSlug' returned exit code $LASTEXITCODE.")
        }
    } catch {
        $Issues.Add("Failed to delete GitHub repository '$OriginSlug': $($_.Exception.Message)")
    }
}


function Invoke-WslBlock {
    param(
        [string]$Script,
        [hashtable]$Environment = $null
    )
    $normalized = ($Script -replace "`r","").Trim()
    if ($Environment -and $Environment.Count -gt 0) {
        $exports = foreach ($item in $Environment.GetEnumerator()) {
            $escapedValue = Escape-WslSingleQuote $item.Value
            "export $($item.Key)='$escapedValue'"
        }
        $normalized = ($exports -join "`n") + "`n" + $normalized
    }
    $output = & wsl.exe -- bash -lc "$normalized" 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Stop-KnownProcesses {
    param([System.Collections.Generic.List[string]]$Issues)
    foreach ($serviceName in @('com.docker.service')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30)) | Out-Null
            } catch {
                $Issues.Add("Unable to stop service '$serviceName': $($_.Exception.Message)")
            }
        }
    }
    $processNames = @('Docker Desktop','DockerCli','com.docker.backend','com.docker.proxy','com.docker.service','Docker','dockerd','Cursor','cursor','node','wsl','wslhost')
    foreach ($name in $processNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            try {
                $procs | Stop-Process -Force -ErrorAction Stop
            } catch {
                $Issues.Add("Unable to stop process '$name': $($_.Exception.Message)")
            }
        }
    }
}

function Remove-Tree {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Issues,
        [int]$Attempts = 5
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq $Attempts) {
                $Issues.Add("Failed to delete '$Path': $($_.Exception.Message)")
                break
            }
            Stop-KnownProcesses -Issues $Issues
            Start-Sleep -Seconds 2
        }
    }
    if (Test-Path -LiteralPath $Path) {
        $Issues.Add("Path still present after cleanup: $Path")
    }
}

function Ensure-WingetRemoved {
    param(
        [string]$PackageId,
        [string]$Label,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($Label)) { return }
    $stillPresent = $false
    $wingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    if ($wingetAvailable -and $PackageId) {
        try {
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $listing = winget list --id $PackageId 2>$null
                if (-not $listing -or $listing -notmatch [Regex]::Escape($PackageId)) { break }
                winget uninstall --id $PackageId --silent --accept-source-agreements --accept-package-agreements *> $null
                Start-Sleep -Seconds 5
            }
            $listing = winget list --id $PackageId 2>$null
            if ($listing -and $listing -match [Regex]::Escape($PackageId)) {
                $stillPresent = $true
            }
        } catch {
            $stillPresent = $true
            $Issues.Add("winget failed to remove $Label: $($_.Exception.Message)")
        }
    } else {
        $stillPresent = $true
    }
    if ($stillPresent) {
        try {
            $package = Get-Package -ProviderName Programs -Name $Label -ErrorAction SilentlyContinue
            if ($package) {
                Uninstall-Package -InputObject $package -Force -ErrorAction Stop
                $stillPresent = $false
            }
        } catch {
            $Issues.Add("Fallback uninstall for $Label failed: $($_.Exception.Message)")
            $stillPresent = $true
        }
    }
    if ($stillPresent) {
        $Issues.Add("$Label may still be installed. Remove it via Apps & Features if present.")
    }
}

function Ensure-WslDistroRemoved {
    param(
        [string]$Name,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $registered = Get-WslDistributions
        if ($registered -notcontains $Name) { return }
        try { & wsl.exe --terminate $Name 2>$null | Out-Null } catch {}
        try { & wsl.exe --unregister $Name 2>$null | Out-Null } catch {
            $Issues.Add("Failed to unregister WSL distribution '$Name': $($_.Exception.Message)")
        }
        Start-Sleep -Seconds 3
    }
    if ((Get-WslDistributions) -contains $Name) {
        $Issues.Add("WSL distribution '$Name' is still registered after multiple attempts.")
    }
}

function Invoke-HostCleanupIfPending {
    param(
        [string]$ScriptPath,
        [System.Collections.Generic.List[string]]$Issues
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return }
    Write-Host "Ensuring Windows host cleanup helper runs..." -ForegroundColor Cyan
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$ScriptPath,"-Elevated" -Verb RunAs -PassThru -ErrorAction Stop
        if ($proc) {
            $proc.WaitForExit(300000) | Out-Null
        }
    } catch {
        $Issues.Add("Unable to launch host cleanup script ($ScriptPath): $($_.Exception.Message)")
    }
    for ($i = 0; $i -lt 180; $i++) {
        if (-not (Test-Path -LiteralPath $ScriptPath)) { return }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $ScriptPath) {
        $Issues.Add("Host cleanup script still present at $ScriptPath. Run it manually as administrator.")
    }
}

function Clear-EnvironmentVariables {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($target in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
        foreach ($name in $Names) {
            try {
                [Environment]::SetEnvironmentVariable($name,$null,$target)
            } catch {
                $Issues.Add("Unable to clear environment variable $name for scope $target: $($_.Exception.Message)")
            }
        }
    }
}

function Verify-EnvironmentVariables {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($target in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
        foreach ($name in $Names) {
            $value = [Environment]::GetEnvironmentVariable($name,$target)
            if ($value) {
                $Issues.Add("Environment variable $name still set for scope $target.")
            }
        }
    }
}

function Verify-DirectoriesGone {
    param(
        [string[]]$Paths,
        [System.Collections.Generic.List[string]]$Issues
    )
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath $path) {
            $Issues.Add("Residual path detected: $path")
        }
    }
}

function Verify-WingetAbsent {
    param(
        [System.Collections.Hashtable[]]$PackageIds,
        [System.Collections.Generic.List[string]]$Issues
    )
    $wingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    foreach ($entry in $PackageIds) {
        $id = $entry['Id']
        $label = $entry['Label']
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if ($wingetAvailable -and $id) {
            try {
                $listing = winget list --id $id 2>$null
                if ($listing -and $listing -match [Regex]::Escape($id)) {
                    $Issues.Add("$label still appears in winget package list.")
                    continue
                }
            } catch {
                $Issues.Add("winget verification for $label failed: $($_.Exception.Message)")
                continue
            }
        }
        try {
            $package = Get-Package -ProviderName Programs -Name $label -ErrorAction SilentlyContinue
            if ($package) {
                $Issues.Add("$label still appears in Apps & Features.")
            }
        } catch {
            $Issues.Add("Unable to verify Apps & Features entry for $label: $($_.Exception.Message)")
        }
    }
}

function Verify-WslDistrosAbsent {
    param(
        [string[]]$Names,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    $registered = Get-WslDistributions
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($registered -contains $name) {
            $Issues.Add("WSL distribution '$name' still registered.")
        }
    }
}

function Save-TerraformSummary {
    param(
        [string]$WslPath,
        [string]$Destination,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    $result = Invoke-WslBlock "if [ -f '$WslPath' ]; then cat '$WslPath'; fi"
    if ($result.ExitCode -ne 0) {
        $Issues.Add("Unable to read Terraform summary from WSL (exit $($result.ExitCode)).")
        return
    }
    if (-not $result.Output) { return }
    $content = ($result.Output -join "`n").Trim()
    if (-not $content) { return }
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -Path $Destination -Value $content -Encoding UTF8
}

function Parse-TerraformSummary {
    param(
        [string]$Path,
        [System.Collections.Generic.List[string]]$Issues
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        $Issues.Add("Terraform teardown summary not found at $Path.")
        return
    }
    try {
        $entries = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in $entries) {
            if ($entry.status -notin @('success','skipped')) {
                $Issues.Add("Terraform ${entry.environment} reported '${entry.status}' (${entry.message}).")
            }
        }
    } catch {
        $Issues.Add("Unable to parse Terraform summary at $Path: $($_.Exception.Message)")
    }
}

$initialLocation = Get-Location
$initialPath = $initialLocation.ProviderPath
try {
    Assert-Administrator

    $issues = [System.Collections.Generic.List[string]]::new()
    $notes  = [System.Collections.Generic.List[string]]::new()
    $temporaryRoots = [System.Collections.Generic.List[string]]::new()

    $repoInfo = Acquire-AiDevRepo -Notes $notes -Issues $issues
    if (-not $repoInfo.Path) {
        throw "Unable to locate or download the ai-dev-platform checkout. Resolve the issues above and rerun the teardown."
    }
    $repoRoot = $repoInfo.Path
    if ($repoInfo.Temporary) {
        $temporaryRoots.Add($repoRoot)
        $notes.Add("Using a temporary archive of ai-dev-platform downloaded to $repoRoot.")
    } else {
        $notes.Add("Using repository at $repoRoot")
    }

    $originSlug = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "origin"
    $upstreamSlug = Get-GitRemoteSlug -RepoPath $repoRoot -Remote "upstream"
    if ([string]::IsNullOrWhiteSpace($upstreamSlug)) { $upstreamSlug = "swb2019/ai-dev-platform" }
    $wslStatus = Ensure-WslReady -Notes $notes -Issues $issues
    if (-not $wslStatus.Ready) {
        if ($wslStatus.PendingReboot) {
            throw "WSL features were enabled. Reboot Windows, then rerun this script to finish the teardown."
        }
        throw "WSL is unavailable; cannot proceed with the full teardown."
    }

    $terraformPath = Ensure-TerraformAvailable -Notes $notes -Issues $issues
    if ($terraformPath) {
        $terraformDir = Split-Path -Parent $terraformPath
        if ($env:PATH -notlike "*$terraformDir*") {
            $env:PATH = "$terraformDir;$env:PATH"
        }
    }

    Ensure-CredentialReadiness -Notes $notes -Issues $issues
    Ensure-InfisicalToken -Notes $notes -Issues $issues

    $summaryCopy = Join-Path $env:ProgramData "ai-dev-platform\uninstall-summary.json"
    $hostScript   = "C:\ProgramData\ai-dev-platform\uninstall-host.ps1"
    $wslSummary   = "/tmp/ai-dev-platform-uninstall-summary.json"
    if (Test-Path -LiteralPath $summaryCopy) { Remove-Item $summaryCopy -Force }

    Stop-KnownProcesses -Issues $issues

    $repoParent = Split-Path -Parent $repoRoot
    if ($repoParent -and (Test-Path -LiteralPath $repoParent)) {
        Set-Location $repoParent
    }

    $wslPath = Convert-WindowsPathToWsl $repoRoot
    if ([string]::IsNullOrWhiteSpace($wslPath)) {
        $issues.Add("Unable to translate repository path '$repoRoot' into a WSL mount.")
    } else {
        $sanitizeScript = @"
set -e
cd '$wslPath'
if command -v find >/dev/null 2>&1; then
  find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
fi
"@
        $sanitized = Invoke-WslBlock $sanitizeScript
        if ($sanitized.ExitCode -ne 0 -and $sanitized.Output) {
            $notes.Add("Shell script normalization reported: $($sanitized.Output -join ' ')")
        }

        $wslScript = @"
set -euo pipefail
cd '$wslPath'
rm -f '$wslSummary'
./scripts/uninstall.sh --full-reset --force --destroy-cloud
if [ -f uninstall-terraform-summary.json ]; then
  cp uninstall-terraform-summary.json '$wslSummary'
fi
"@
        Write-Host "Executing teardown inside WSL..." -ForegroundColor Cyan
        $result = Invoke-WslBlock $wslScript
        if ($result.Output) {
            $result.Output | ForEach-Object { Write-Host $_ }
        }
        if ($result.ExitCode -ne 0) {
            $issues.Add("WSL uninstall script exited with code $($result.ExitCode).")
        } else {
            Save-TerraformSummary -WslPath $wslSummary -Destination $summaryCopy -Issues $issues
        }
    }

    Invoke-HostCleanupIfPending -ScriptPath $hostScript -Issues $issues
    Invoke-GitHubForkDeletion -OriginSlug $originSlug -UpstreamSlug $upstreamSlug -Notes $notes -Issues $issues

    Stop-KnownProcesses -Issues $issues

    $pathsToRemove = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        $repoRoot,
        "C:\dev\ai-dev-platform",
        "$env:UserProfile\ai-dev-platform",
        "$env:ProgramData\ai-dev-platform",
        "$env:ProgramData\ai-dev-platform\teardown-cache",
        "$env:ProgramData\ai-dev-platform\terraform",
        "$env:LOCALAPPDATA\ai-dev-platform",
        "$env:LOCALAPPDATA\Programs\Cursor",
        "$env:LOCALAPPDATA\Cursor",
        "$env:APPDATA\Cursor",
        "$env:UserProfile\.cursor",
        "$env:UserProfile\.codex",
        "$env:UserProfile\.cache\Cursor",
        "$env:UserProfile\.cache\ms-playwright",
        "$env:UserProfile\.cache\ai-dev-platform",
        "$env:UserProfile\.pnpm-store",
        "$env:UserProfile\.turbo",
        "$env:UserProfile\.npm",
        "$env:UserProfile\AppData\Local\Docker",
        "$env:UserProfile\AppData\Roaming\Docker",
        "$env:ProgramData\DockerDesktop",
        "$env:ProgramData\Docker",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Docker Desktop.lnk",
        "$env:UserProfile\Desktop\Docker Desktop.lnk",
        "$env:Public\Desktop\Docker Desktop.lnk"
    )) {
        Add-UniquePath -List $pathsToRemove -Path $path
    }

    foreach ($path in $pathsToRemove) {
        Remove-Tree -Path $path -Issues $issues -Attempts 5
    }

    Clear-EnvironmentVariables -Names @('INFISICAL_TOKEN','GH_TOKEN','WSLENV','DOCKER_CERT_PATH','DOCKER_HOST','DOCKER_DISTRO_NAME') -Issues $issues

    foreach ($pkg in @(
        @{ Id = 'Cursor.Cursor';            Label = 'Cursor' },
        @{ Id = 'Docker.DockerDesktop';     Label = 'Docker Desktop' },
        @{ Id = 'Docker.DockerDesktop.App'; Label = 'Docker Desktop App' },
        @{ Id = 'Docker.DockerDesktopEdge'; Label = 'Docker Desktop Edge' }
    )) {
        Ensure-WingetRemoved -PackageId $pkg.Id -Label $pkg.Label -Issues $issues
    }

    $distroCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'ai-dev-platform',
        'Ubuntu-22.04-ai-dev-platform',
        'Ubuntu-20.04-ai-dev-platform',
        'Ubuntu-22.04',
        'Ubuntu-24.04',
        'Ubuntu'
    )) {
        Add-UniqueString -List $distroCandidates -Value $name
    }
    foreach ($scope in @([EnvironmentVariableTarget]::User,[EnvironmentVariableTarget]::Machine)) {
        $value = [Environment]::GetEnvironmentVariable('DOCKER_DISTRO_NAME',$scope)
        Add-UniqueString -List $distroCandidates -Value $value
    }
    foreach ($name in Get-WslDistributions) {
        if ($name -match 'ai-dev' -or $name -match 'ubuntu') {
            Add-UniqueString -List $distroCandidates -Value $name
        }
    }
    foreach ($name in $distroCandidates) {
        Ensure-WslDistroRemoved -Name $name -Issues $issues
    }

    Stop-KnownProcesses -Issues $issues

    Verify-DirectoriesGone -Paths ($pathsToRemove.ToArray()) -Issues $issues
    Verify-EnvironmentVariables -Names @('INFISICAL_TOKEN','GH_TOKEN','WSLENV','DOCKER_CERT_PATH','DOCKER_HOST','DOCKER_DISTRO_NAME') -Issues $issues
    Verify-WingetAbsent -PackageIds @(
        @{ Id = 'Cursor.Cursor';            Label = 'Cursor' },
        @{ Id = 'Docker.DockerDesktop';     Label = 'Docker Desktop' },
        @{ Id = 'Docker.DockerDesktop.App'; Label = 'Docker Desktop App' },
        @{ Id = 'Docker.DockerDesktopEdge'; Label = 'Docker Desktop Edge' }
    ) -Issues $issues
    Verify-WslDistrosAbsent -Names ($distroCandidates.ToArray()) -Issues $issues

    if (Test-Path -LiteralPath $summaryCopy) {
        Parse-TerraformSummary -Path $summaryCopy -Issues $issues
    } else {
        $issues.Add("Terraform teardown summary not generated; confirm remote infrastructure manually.")
    }

    foreach ($tempRoot in $temporaryRoots) {
        try {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
            }
        } catch {
            $notes.Add("Temporary repository copy at '$tempRoot' could not be deleted automatically: $($_.Exception.Message)")
        }
    }

    if ($notes.Count -gt 0) {
        Write-Host ""
        Write-Host "Notes:" -ForegroundColor DarkCyan
        foreach ($note in $notes) {
            Write-Host " - $note"
        }
    }

    if ($issues.Count -eq 0) {
        Write-Host ""
        Write-Host "✅ Full teardown complete and verified. Reboot the machine to finish releasing Windows resources." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Warning "Cleanup verification found issues:"
        foreach ($issue in $issues) {
            Write-Host " - $issue" -ForegroundColor Yellow
        }
        throw "Automated reset finished with issues. Resolve the items above."
    }
} finally {
    if ($initialPath -and (Test-Path -LiteralPath $initialPath)) {
        Set-Location $initialPath
    } else {
        Set-Location "$( $env:SystemDrive )\"
    }
}
```

When the script prints the ✅ success message, reboot the machine to make sure Docker Desktop, WSL, and associated services release their handles. If it reports issues, address them and rerun before provisioning the environment again.
