# Dedicated Repository Checks

This guide explains how to run validation for Codex or Claude sessions from a dedicated remote repository while keeping the canonical `ai-dev-platform` repo read-only for humans.

## 1. Provision a private automation repo

- Create a new private GitHub repository (e.g. `agent-run-ai-dev-platform`).
- Enable branch protection on `main` with required status checks and signed commits.
- Add deploy keys or GitHub App credentials scoped only to this repository; do not grant automation access back to the primary platform repo.

## 2. Materialise a sandbox workspace

From a trusted checkout of `ai-dev-platform`:

```bash
scripts/agent/create-project-workspace.sh --name agent-run
cd ../project-workspaces/agent-run
git init
git remote add origin git@github.com:YOUR-ORG/agent-run-ai-dev-platform.git
git add .
git commit -m "Initial agent workspace import"
git push -u origin main
```

Notes:

- Regenerate the workspace whenever you promote upstream changes to keep drift low.
- Keep the `.platform-sandbox` marker intact so guardrails such as `run-sandbox-container.sh` recognise the workspace.

## 3. Copy automation scripts

- Copy `scripts/agent-validate.sh` from the platform repo; keep it at the repository root so CI and human operators share a single entry point.
- Optional: mirror additional utilities (`scripts/test-suite.sh`, `scripts/container/`) if agents need them.
- Track copied scripts inside the automation repo so they receive updates through PRs rather than ad-hoc transfers.

## 4. Configure GitHub Actions for agent checks

Inside the automation repo, add `.github/workflows/agent-checks.yml`:

```yaml
name: Agent Checks

on:
  push:
    branches: [main]
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v2
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'pnpm'
      - name: Install dependencies
        run: pnpm install
      - name: Agent validation
        run: ./scripts/agent-validate.sh
```

Hardening tips:

- Pin GitHub Action SHAs for production usage.
- Add required secrets (e.g. Playwright service account) through repository settings, never from the sandbox.
- Enforce status checks in branch protection so merges require passing agent validation.

## 5. Running agents against the dedicated repo

1. Launch a sandbox container on the remote machine:
   ```bash
   scripts/agent/run-sandbox-container.sh \
     --workspace /path/to/project-workspaces/agent-run
   ```
   Append `--with-network` only when dependency installation is necessary.
2. Inside the container (or VM), point Codex/Claude to the workspace path.
3. Commit and push changes; GitHub Actions runs `agent-checks.yml` automatically.
4. Review CI output and merge only validated pull requests.

## 6. Maintenance and monitoring

- Schedule `ansible-pull` or equivalent to refresh the workspace and workflow files from the platform repo.
- Rotate deploy keys and automation tokens on a quarterly cadence.
- Ship CI logs to your central observability stack (e.g. GitHub Actions OIDC into CloudWatch or Grafana Cloud) for audit trails.
- Inspect the automation repo monthly to confirm scripts still match the upstream platform versions.

Following this flow keeps agent execution isolated in a dedicated repository, while automated checks stay aligned with the authoritative tooling from `ai-dev-platform`.
