# Supply Chain Security

The web application supply chain couples container hardening, vulnerability scanning, SBOM generation, and artifact signing into an automated workflow. This document captures the tools, local developer experience, and CI/CD integration added in Phase 3.

## Tooling Overview

| Capability             | Tool                                                                                      | Enforcement                                                    |
| ---------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Container builds       | Docker, multi-stage image in `apps/web/Dockerfile`                                        | Distroless Node.js runtime (`nonroot`), standalone output      |
| Vulnerability scanning | [Trivy](https://aquasecurity.github.io/trivy) & [Grype](https://github.com/anchore/grype) | Build fails on High/Critical (Trivy) and High (Grype) findings |
| SBOM generation        | [Syft](https://github.com/anchore/syft)                                                   | CycloneDX JSON, published as CI artifact                       |
| Signing & attestation  | [Cosign](https://docs.sigstore.dev/cosign/overview/)                                      | Keyless OIDC signing + SBOM attestation                        |

All binaries are installed in the development container (`.devcontainer/Dockerfile`) and validated during onboarding. CI installs pinned versions to guarantee repeatability.

## Local Workflow

Prerequisites: Docker daemon, Trivy, Grype, Syft, and Cosign must resolve on `PATH`. Running `scripts/onboard.sh` verifies the requirements.

Common commands are exposed through `pnpm` scripts:

```bash
# Build the optimized Next.js image (apps/web)
pnpm docker:build:web

# Scan the last built image (fails on disallowed severities)
pnpm docker:scan:web

# Generate a CycloneDX SBOM to artifacts/sbom/
pnpm docker:sbom:web

# Sign and attest the pushed image + SBOM via keyless Cosign
IMAGE_REPO=ghcr.io/${GITHUB_REPOSITORY:-org/repo}/web \
IMAGE_TAG=local-dev \
pnpm docker:sign:web

# End-to-end release helper (build → scan → sbom → sign)
pnpm docker:release:web
```

Environment overrides:

| Variable                             | Default                                                    | Purpose                                                   |
| ------------------------------------ | ---------------------------------------------------------- | --------------------------------------------------------- |
| `IMAGE_REPO`                         | `local/ai-dev-platform-web` or `ghcr.io/<owner>/web` in CI | Registry/repository for image, signature, and attestation |
| `IMAGE_TAG`                          | `dev`                                                      | Mutable tag for local builds (CI sets commit SHA)         |
| `SBOM_OUTPUT`                        | `artifacts/sbom/web-cyclonedx.json`                        | Destination for Syft output                               |
| `TRIVY_IGNORE_FILE` / `GRYPE_CONFIG` | `.trivyignore` / `.grype.yaml`                             | Optional risk accept lists                                |

> **Note:** Cosign keyless signing expects ambient OIDC credentials. When running locally, authenticate against OIDC (e.g., `gcloud auth login --workload` or `az login --federated-token`) or provide a private key.

## CI/CD Integration

The `supply_chain` job in `.github/workflows/ci.yml` depends on the `quality-gates` test suite and executes the following steps:

1. Install pinned versions of Trivy, Grype, Syft, and Cosign.
2. Build the Docker image via `pnpm docker:build:web` using the multi-stage Dockerfile.
3. Run `pnpm docker:scan:web`, failing the pipeline on High/Critical findings.
4. Generate a CycloneDX SBOM (`pnpm docker:sbom:web`) and upload it as an artifact.
5. Push the image to `ghcr.io/${{ github.repository }}/web:${{ github.sha }}`.
6. Sign the pushed image and publish an attestation containing the SBOM with Cosign keyless mode.

The job grants `packages: write` to publish to GHCR and `id-token: write` to mint the OIDC token required for Cosign keyless signing.

Artifacts:

- `artifacts/sbom/web-<sha>-cyclonedx.json`: Uploaded SBOM for downstream consumers.
- Cosign signatures and attestations stored alongside the GHCR image reference.

## Hardened Docker Image

`apps/web/Dockerfile` implements a three-stage build:

1. **deps** – pre-fetch PNPM dependencies for the web workspace scope.
2. **builder** – installs workspace dependencies and runs `pnpm --filter @ai-dev-platform/web build` to generate the Next.js standalone output.
3. **runner** – copies the standalone build, static assets, and public files into the distroless `nodejs20-debian12:nonroot` image (no package manager, runs as `nonroot`) and exposes port 3000.

This layout minimizes final image size, avoids shipping the PNPM store, and enforces least privilege execution.

## Next Steps

- Introduce automated vulnerability baseline management (`.trivyignore`, `.grype.yaml`) once specific findings are triaged.
- Extend attestation coverage with additional predicates (e.g., SLSA provenance) as supply chain requirements evolve.
