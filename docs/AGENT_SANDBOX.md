# Agent Sandbox Workflow

Codex and Claude agents are powerful but untrusted. To keep the AI Dev Platform itself immutable, work must flow through isolated project workspaces that never expose platform governance tooling or CI credentials.

## Overview

1. **Platform repository stays read-only.** Only the human maintainer edits or merges changes under the main AI Dev Platform repository.
2. **Agents build inside sandboxed workspaces.** Each project gets its own copy of the application code, detached from the platform Git history.
3. **Promotion is manual.** The human reviews agent output, then selectively promotes artifacts (commits, manifests, container digests) back into trusted pipelines.

## Creating a Workspace

Use the helper script to materialise a sandbox:

```bash
scripts/agent/create-project-workspace.sh --name demo-app
```

Options:

- `--destination PATH` – parent directory for workspaces (default: `../project-workspaces` relative to the platform repo).
- `--remote URL` – optional Git remote to add inside the new workspace.
- `--with-platform-files` – include deployment/infra automation if the agent legitimately needs them.

The script copies developer tooling (`apps/`, `packages/`, `scripts/container/`, etc.) while excluding:

- `.git/` and other Git metadata
- Governance directories (`deploy/`, `.github/`, `infra/`, `docs/`) by default
- Hardening scripts (`scripts/github-hardening.sh`, `scripts/policy/`, onboarding helpers)

After the copy a `.platform-sandbox` marker file is written so it is obvious the directory is detached from the platform repo.

## Running Agents in a Constrained Container

Keep Codex/Claude inside a locked-down container with no access to host secrets:

```bash
scripts/agent/run-sandbox-container.sh --workspace ../project-workspaces/demo-app
```

The helper wraps `docker run` and applies defensive flags by default:

- `--read-only`, dropped capabilities, and `--security-opt no-new-privileges`
- Memory/CPU limits (`--memory 2g`, `--cpus 2`)
- `--network none` to eliminate outbound connectivity (pass `--with-network` only when supervised dependency installs are unavoidable)
- Bind-mount of the workspace at `/workspace`, the only host path the agent can touch

For additional isolation:

- Use gVisor/Kata/Firecracker by configuring Docker/Containerd to run with `--runtime=runsc` (or equivalent) before starting the container.
- Run the container on a hardened host (dedicated VM or WSL2 distro) with no cached cloud credentials.
- Destroy and recreate containers per session to guarantee a clean slate.
- The script refuses to mount directories lacking the `.platform-sandbox` marker unless you pass `--allow-non-sandbox`; avoid overriding this unless you are deliberately auditing the workspace.

## Agent Usage Model

1. Point the agent to the sandbox directory. It can install dependencies (`pnpm install`), run tests, and modify code freely.
2. When ready, the agent (or you) commits into the sandbox repository. Push to a separate GitHub repository dedicated to the project.
3. Review the diff manually. Promote changes back to the platform only if they touch shared tooling, and do so through signed commits.

## Manual Promotion Checklist

Before copying code back into the platform repository:

1. Review agent commits line-by-line.
2. Manually apply accepted changes into the platform repo (e.g., via `git cherry-pick` or manual edits).
3. Run validation (`./scripts/agent-validate.sh`) in the platform repo.
4. Sign and merge through GitHub with branch protection enforced.

## Operational Tips

- Store sandbox paths outside the platform repository to avoid accidental syncing.
- Keep sandbox Git remotes private or ephemeral; they do not need access to platform secrets.
- Rotate sandboxes periodically. Regenerate them per feature branch or per release candidate to minimise long-lived agent state.
- If a sandbox ever needs platform automation (Terraform, deployment manifests), recreate it with `--with-platform-files` and audit agent actions closely.
- Launch agents through `run-sandbox-container.sh` and keep networking disabled by default.
- Prefer hardware-backed or hypervisor sandboxes for high-trust workloads; update Docker runtime configuration accordingly.

Following this workflow ensures agents remain productive while the AI Dev Platform stays immutable and under explicit human control.
