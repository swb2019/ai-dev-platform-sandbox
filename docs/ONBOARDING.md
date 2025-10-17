# Onboarding Guide

## Prerequisites

- Node.js 20.x (project is tested with the >=20 <21 range specified in package.json).
- PNPM 9 (workspace expects pnpm 9.12.0). Enable via corepack if not already configured.
- Turbo CLI (installed through workspace devDependencies).
- Playwright system dependencies for Chromium (GitHub Actions installs them automatically; locally run `pnpm --filter @ai-dev-platform/web exec playwright install --with-deps` once).

## Initial Setup

1. Install dependencies from the repository root:
   pnpm install
2. Confirm the workspace structure:
   - apps/web – Next.js app (App Router + Tailwind CSS).
   - packages/tsconfig – Shared TypeScript presets.
   - packages/eslint-config-custom – Centralized ESLint rules.
3. On Windows, run the elevated bootstrap helper (installs WSL2, sets the selected distro as default, installs Docker Desktop—with winget, direct-download fallback, or a supplied installer—and executes the consolidated setup). Re-run the helper after completing any prompts; it will resume automatically:
   ```
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 [-DockerInstallerPath C:\path\to\DockerDesktopInstaller.exe]
   ```
   Add `-RepoSlug your-user/ai-dev-platform`, `-Branch feature`, or set `DOCKER_DESKTOP_INSTALLER` when operating behind strict proxies.
4. Run the consolidated setup wrapper if you prefer a single command (already invoked automatically by the Windows helper):
   ./scripts/setup-all.sh
   (installs prerequisite packages/tooling, validates Docker, runs onboarding, editor update/verify, infrastructure bootstrap, hardening, and finishes with automated verification: `docker info`, `pnpm lint`, `pnpm type-check`, `pnpm --filter @ai-dev-platform/web test -- --runInBand`. Each verification reruns automatically (Docker setup helper or `pnpm install --frozen-lockfile`, lint auto-fix, Playwright reinstall, etc.) before failing. On WSL the script can trigger the Docker Desktop installer—complete Windows prompts or reboot if asked, enable WSL integration, then rerun until Docker is detected. Use `SKIP_POST_CHECKS=1 ./scripts/setup-all.sh` to bypass verification, `POST_CHECK_MAX_RETRIES=5` to expand recovery attempts, and inspect logs under `tmp/postcheck-*` if an issue persists. The script records progress in `tmp/setup-all.state`, so you can rerun it to resume where it left off; set `RESET_SETUP_STATE=1` if you need to force every step to re-execute.)
5. Provision the cloud infrastructure manually if you skipped the wrapper:
   ./scripts/bootstrap-infra.sh
6. Populate GitHub environment secrets (requires `gh auth login`; defaults are detected from Terraform outputs):
   ./scripts/configure-github-env.sh staging
   ./scripts/configure-github-env.sh prod
7. Update Cursor and editor extensions to the latest marketplace versions:
   ./scripts/update-editor-extensions.sh
   ./scripts/verify-editor-extensions.sh --strict
   Commit `config/editor-extensions.lock.json` with the captured versions.
8. Review the shared task manifest and update it with your assignments:
   ./scripts/task-context.sh --show
   ./scripts/task-context.sh --set currentGoal "Investigate login UX"

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

## Helpful Commands

- `pnpm format:check` – Validates formatting without writing changes.
- `pnpm build --filter @ai-dev-platform/web` – Generates a production build.
- `pnpm clean` – Removes build artifacts defined in turbo.json.

## Support

If you encounter setup issues, create a ticket in the engineering backlog with reproduction steps and include outputs from `pnpm env use --global` and `pnpm install`.
