# General

- Work from `/workspaces/ai-dev-platform` and use `pnpm` for Node.js tasks.
- Sync with the current project plan via `./scripts/task-context.sh --show` before each session; record changes with `--set`.
- Before significant changes or hand-off, run `./scripts/git-sync-check.sh` to confirm the branch is in sync.
- Never work directly on `main`; create a feature branch. When the task is ready, run `./scripts/push-pr.sh` to open a PR and enable auto-merge, then `./scripts/monitor-pr.sh` to watch it until GitHub merges.
- Keep the workspace reproducible: `pnpm install --frozen-lockfile`, then run `pnpm lint`, `pnpm type-check`, and targeted tests affected by the change.
- Use `./scripts/update-editor-extensions.sh` when updates appear; commit the updated `config/editor-extensions.lock.json`, then run `./scripts/verify-editor-extensions.sh --strict` before pushing.
- Document commands that modify state or produce artifacts so humans can reproduce the results.
- Follow TDD: write or update failing tests before implementing features, and run `./scripts/test-suite.sh` frequently to keep the loop green. Reference `docs/TDD_GUIDE.md` for the detailed loop.

# Codex

- Prefer `bash -lc` invocations with `set -euo pipefail` for multi-line scripts.
- Surface any policy or permission blocks immediately instead of retrying silently.

# Claude

- When context feels insufficient, request human clarification before continuing.
- Keep responses concise and oriented around diff-ready changesets.
- When implementing behavior, describe the failing test first, then the fix, and mention the passing result from `./scripts/test-suite.sh`. Update `config/task-context.json` with remaining TODOs as you wrap up.
