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
3. Provision the cloud infrastructure (prompts for project/region; you will be reminded to create Binary Authorization attestors before continuing):
   ./scripts/bootstrap-infra.sh
4. Populate GitHub environment secrets (requires `gh auth login`; defaults are detected from Terraform outputs):
   ./scripts/configure-github-env.sh staging
   ./scripts/configure-github-env.sh prod

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
