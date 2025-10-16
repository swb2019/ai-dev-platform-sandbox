# Decision Playbook

Use this playbook to resolve ambiguity without pausing for human guidance. Follow the steps in order; document major decisions in `config/task-context.json` and relevant commit messages.

## 1. Requirement Gaps

1. Re-read `docs/agents/EXECUTION_SPEC.md` and the task context.
2. If behaviour is unspecified, search existing patterns in the codebase (tests, components, Terraform modules).
3. Choose the option that best preserves security requirements and existing user experience. If still tied, prefer the solution with more automated test coverage.

## 2. UI & UX Decisions

- Mirror established patterns in `apps/web/src/app` (component structure, Tailwind utility usage, accessibility attributes).
- Maintain mobile-first responsive design; verify with Playwright or story-driven tests when feasible.
- Introduce new design tokens only if they align with `tailwind.config.ts`; otherwise extend the theme centrally before use.

## 3. Infrastructure & DevOps

- Changes to Terraform should favour module composition over copy-paste. Update both `modules/` and `envs/` as needed.
- When secrets are required, store references (not values) and update the environment README with retrieval instructions.
- For Kubernetes overlays, ensure patches remain deterministic; never hardcode image tags—use digests supplied by CI.

## 4. Dependency Management

- Use pnpm workspaces. Add dependencies with `pnpm add --filter <package> <dep>@<version>`.
- Prefer well-supported, security-reviewed packages. Record rationale when adding new dependencies in the PR description.
- Update shared configs (`packages/eslint-config-custom`, `packages/tsconfig`) when cross-cutting changes occur.

## 5. Testing Strategy

- Begin with a failing test (unit or E2E). If writing tests is impractical (e.g., GCP IAM changes), document why in the PR and propose an alternative validation method.
- For UI changes, combine Jest/Testing Library checks with Playwright assertions when behaviour spans multiple components.
- Infrastructure changes must include `terraform plan` output and, when feasible, automated validation using `terraform validate` or policy checks.

## 6. Error Handling & Fallbacks

- If a command fails because of missing credentials or rate limits, mock the external dependency, stub the interaction, and record the expectation in docs.
- When long-running jobs exceed time limits, break the work into resumable steps and document progress markers.
- On flaky tests, quarantine only as a last resort: reproduce, fix root cause, add deterministic waits or mocks, and update the risk register.

## 7. Communication Protocol

- Update `config/task-context.json` after major decisions so subsequent runs inherit context.
- Record outstanding questions in `remainingTodos`; include suggested next actions.
- Only stop execution when security, data loss, or irreversible deployment risks are present. In all other cases, proceed with the safest documented assumption and capture it for review.
