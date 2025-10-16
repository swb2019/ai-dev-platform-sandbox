# Agent Kickoff Prompt Template

Copy this template when launching Codex or Claude sessions. Replace bracketed sections with task-specific details while keeping the shared context intact.

```markdown
<environment_context>
<cwd>/workspaces/ai-dev-platform</cwd>
<approval_policy>never</approval_policy>
<sandbox_mode>danger-full-access</sandbox_mode>
<network_access>enabled</network_access>
<shell>bash</shell>
</environment_context>

# Project Brief

- Repo: `ai-dev-platform` (Next.js 14 app + Terraform + GKE delivery)
- Core docs: `docs/agents/EXECUTION_SPEC.md`, `docs/AGENT_HANDBOOK.md`
- Current goal: [describe the feature/fix]
- Acceptance criteria:
  1. [...]
  2. [...]
- Constraints & priorities:
  - Security first (see `docs/AGENT_PROTOCOLS.md`)
  - Tests must be added/updated (`docs/TDD_GUIDE.md`)
  - Automation scripts should remain single-source (`scripts/test-suite.sh`, `scripts/push-pr.sh`)

# Implementation Notes

- Existing context: `config/task-context.json`
- Risks to monitor: `docs/agents/RISK_REGISTER.md`
- Decision rules: `docs/agents/DECISION_PLAYBOOK.md`
- Data fixtures: `fixtures/web/feature-cards.json` (extend if new marketing copy is needed)

# Tasks

1. [task step 1]
2. [task step 2]
3. [task step 3]

# Validation

- Run `./scripts/test-suite.sh` and capture output.
- Record `./scripts/git-sync-check.sh` results.
- Update docs/playbooks if assumptions change.
```

Keep the template in version control; update it whenever workflows evolve so every autonomous run starts with complete knowledge.
