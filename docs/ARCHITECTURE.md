# Architecture Overview

## Monorepo Structure

- apps/web — Marketing-facing Next.js 14 application using the App Router and Tailwind CSS.
- packages/tsconfig — Shared TypeScript configuration presets consumed across the workspace.
- packages/eslint-config-custom — Centralized ESLint configurations for base projects and Next.js apps.
- docs — Knowledge base for platform documentation.

## Environment Topology

- **Staging** – canonical integration environment targeted by the `Deploy Staging` workflow. Deployments roll to the staging GKE Autopilot cluster, expose traffic through the Gateway API, and are automatically validated by Playwright against the Gateway external IP before completing.
- **Production** – mirrors the staging topology on a separate GKE Autopilot cluster. Promotion occurs via tagged releases and applies the production Kustomize overlay with higher replica counts and the production hostname.
- **Infrastructure as Code** – Terraform modules under `infra/terraform` compose shared building blocks (network, services, GKE Autopilot, and Artifact Registry). Environment directories (`envs/staging`, `envs/prod`) supply unique CIDR ranges, Workload Identity bindings, and Binary Authorization attestors.

## Application Platform

The web application is built with Next.js 14 App Router on React 18. Server Components render the marketing experience while keeping the bundle lean, and Client Components are used only where interactivity is required. A shared utility library at src/lib/utils.ts exposes a cn helper that merges class names via clsx and tailwind-merge to prevent style collisions.

### Styling

Tailwind CSS v4 drives the design system with a bespoke palette defined in tailwind.config.ts. Global CSS layers apply gradient backgrounds and typography defaults, while components consume utilities through the cn helper.

### TypeScript

TypeScript strict mode is enforced through the shared packages/tsconfig presets:

- base.json targets ES2022 with strict, noImplicitAny, and esModuleInterop enabled.
- nextjs.json extends the base, preserves JSX, registers the Next.js plugin, and configures type roots.

### Linting & Formatting

ESLint rules are centralized in packages/eslint-config-custom, combining TypeScript recommendations with security scanning (eslint-plugin-security) and maintainability rules (eslint-plugin-sonarjs). The Next.js specific preset extends the base and layers in @next/next rules. Prettier is configured at the repository root for consistent formatting.

### Build Orchestration

Turbo (turbo.json) coordinates shared scripts (dev, build, lint, type-check, and format) across packages. The web app emits .next/\*\* artifacts that Turbo can cache to speed up repeat builds.

## Runtime Infrastructure

- **GKE Autopilot** – workloads run on Google Kubernetes Engine Autopilot clusters, enforcing pod security by design while delegating node management to Google. Workload Identity binds the `web` namespace ServiceAccount to dedicated Google service accounts per environment.
- **Gateway API** – traffic reaches the application through the Gateway controller (`deploy/k8s/base/gateway.yaml`) with per-environment HTTPRoute overlays that set hostnames and tie the Gateway listener to the `web` service.
- **Supply Chain** – container images built from `apps/web/Dockerfile` are scanned, signed (Cosign), and attested before deployment. Kustomize overlays inject the immutable digest resolved during CI so only verified artifacts roll out.

## Security & Quality Considerations

- Security rules detect unsafe regexes, object injection, and non-literal filesystem access.
- SonarJS rules highlight duplicated logic, complex branches, and other maintainability issues.
- Strict TypeScript eliminates implicit any usage and enforces type-safe imports, reducing runtime defects.
- Playwright end-to-end tests run against the Gateway endpoint after each staging deploy, ensuring core journeys stay functional before promotion.

## Future Enhancements

- Add shared UI primitives under packages/ui for reuse across future apps.
- Extend the lint config with custom rules for accessibility and localization.
- Integrate CI workflows to run pnpm lint, pnpm type-check, and future test suites on pull requests.
