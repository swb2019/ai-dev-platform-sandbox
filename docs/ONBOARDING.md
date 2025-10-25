# Onboarding Guide

> **Scope:** The automated workflow targets Windows 11 (or Windows 10 22H2+) with WSL2, administrator access, outbound HTTPS to GitHub/Docker/Cursor endpoints, and a GitHub account that has administrator permissions on the target repository. You must already have a Google Cloud project with billing enabled and a GitHub repository/org where you have admin rights. macOS/Linux developers should provision a Windows VM or adapt the scripts manually.

### Before you run the bootstrap

1. **Create a Google Cloud project with billing**
   - Visit <https://console.cloud.google.com/projectcreate>, create a project, and note its project ID.
   - Link a billing account (Billing → Link a billing account)
   - Optional but helpful: enable the Cloud Resource Manager API.

2. **Create or fork a GitHub repository**
   - Fork `swb2019/ai-dev-platform` or create an empty repository in your organization.
   - Confirm your GitHub account has "Admin" permissions on that repo.

3. **(Optional) Authenticate the GitHub CLI ahead of time**
   ```bash
   gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,admin:org"
   ```

## First-time setup checklist

1. **Clone the repository**

   ```powershell
   # Windows (PowerShell)
   git clone https://github.com/swb2019/ai-dev-platform.git C:\dev\ai-dev-platform
   ```

   ```bash
   # macOS / Linux
   git clone https://github.com/swb2019/ai-dev-platform.git
   cd ai-dev-platform
   ```

2. **Sync your fork (optional but recommended)**

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\sync-sandbox.ps1
   ```

   This signs in the GitHub CLI, creates the fork if it does not exist, and force-updates your `main` with the latest upstream commits.

3. **Run the consolidated setup**
   - Windows (elevated PowerShell):
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1
     ```
   - macOS / Linux / inside WSL:
     ```bash
     ./scripts/setup-all.sh
     ```
     The wrapper installs prerequisites, ensures Docker availability, runs onboarding, infrastructure bootstrap, repository hardening, and finishes with lint/type-check/test verification. It records checkpoints under `tmp/setup-all.state` (or `~/.cache/ai-dev-platform/setup-state` on WSL), so reruns are safe. Use `RESET_SETUP_STATE=1 ./scripts/setup-all.sh` to force every step. Post-check logs are under `tmp/postcheck-*`.

4. **Complete GitHub CLI authentication when prompted**
   Repository hardening launches `gh auth login --web` (Windows and WSL), refreshes the token scopes (`repo`, `workflow`, `admin:org`), and confirms the signed-in user has administrator rights on the repository. The helper relays each OAuth link to your Windows browser automatically; if it does not open, copy the printed URL manually. If you cancel or sign in with a non-admin account, rerun `./scripts/github-hardening.sh` later—it will keep prompting until authentication succeeds with an administrator.

5. **Sign into Cursor, Codex, and Claude Code extensions**
   - Launch Cursor (the Windows bootstrap installs it via winget and, if that fails, fetches and caches the newest signed Windows installer from Cursor's GitHub releases—respecting corporate proxy env vars—or honors `-CursorInstallerPath` / `CURSOR_INSTALLER_PATH` overrides including directories or `.zip` archives containing `CursorSetup*.exe`).
   - Sign into GitHub inside Cursor.
   - Open the Command Palette and run “Codex: Sign In” followed by “Claude Code: Sign In”.

6. **Verify the workspace**

   ```bash
   cd ~/ai-dev-platform   # or the repo root on macOS/Linux
   pnpm --filter @ai-dev-platform/web dev
   ```

   The setup script already ran lint (`pnpm lint`), type-check (`pnpm type-check`), and unit tests (`pnpm --filter @ai-dev-platform/web test -- --runInBand`). Re-run those before opening a PR.

7. **Provision infrastructure (required for deployments)**

   The Windows helper offers to run these commands automatically. If you skipped that step or need to rerun manually, execute the following inside WSL:

   ```bash
   gcloud auth login
   gcloud auth application-default login
   ./scripts/bootstrap-infra.sh
   ./scripts/configure-github-env.sh staging
   ./scripts/configure-github-env.sh prod
   ```

   Provide your GCP project ID, region, and Terraform state bucket when prompted. Set `INFISICAL_TOKEN` if you use Infisical-managed secrets; the bootstrap now offers to paste an existing token and only generates one if you explicitly choose to.

8. **Update editor extensions when versions change**

   ```bash
   ./scripts/update-editor-extensions.sh
   ./scripts/verify-editor-extensions.sh --strict
   ```

   Commit the updated `config/editor-extensions.lock.json`.

9. **Review the shared task manifest**
   ```bash
   ./scripts/task-context.sh --show
   ./scripts/task-context.sh --set currentGoal "Investigate login UX"
   ```

## Development Workflow

- Start the web app with hot reload:
  pnpm --filter @ai-dev-platform/web dev
- Run lint checks using the shared configuration:
  pnpm lint --filter @ai-dev-platform/web
- Type-check the application (strict mode enforced):
  pnpm type-check --filter @ai-dev-platform/web
- Execute unit tests (Jest):
  pnpm --filter @ai-dev-platform/web test
- Run Playwright end-to-end tests (requires a running target; set `E2E_TARGET_URL` or start `pnpm --filter @ai-dev-platform/web dev` in another terminal):
  pnpm --filter @ai-dev-platform/web test:e2e
- Run the full suite before commits:
  ./scripts/test-suite.sh
- Format code with Prettier:
  pnpm --filter @ai-dev-platform/web format

## Adding New Packages or Apps

1. Add the workspace entry inside pnpm-workspace.yaml if it falls outside existing globs.
2. For TypeScript projects, extend from packages/tsconfig/base.json or nextjs.json as appropriate.
3. For linting, extend @ai-dev-platform/eslint-config-custom (or the Next.js variant).
4. Run `pnpm install --no-frozen-lockfile` after updating package.json files to refresh the lockfile.

## Helpful commands

- `pnpm --filter @ai-dev-platform/web dev` – Next.js dev server.
- `pnpm lint` / `pnpm type-check` / `pnpm --filter @ai-dev-platform/web test` – Main quality gates.
- `pnpm --filter @ai-dev-platform/web test:e2e` – Playwright end-to-end tests (set `E2E_TARGET_URL` when pointing at a deployed environment).
- `pnpm format:check` – Validate formatting without editing files.
- `pnpm clean` – Remove build artifacts defined in `turbo.json`.

## Need help?

- Re-run `./scripts/setup-all.sh` (it resumes automatically).
- Inspect `tmp/postcheck-*` for verification failures.
- Review `~/ai-dev-platform/tmp/github-hardening.pending` if repository hardening paused for manual action.
- Still blocked? File an engineering ticket with the `tmp` logs, `pnpm env use --global`, and `pnpm --version`.
