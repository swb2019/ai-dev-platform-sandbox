# Deployment Guide

This document explains how the AI Dev Platform web service is packaged for Kubernetes, exposed through the Gateway API, and promoted between environments via GitHub Actions.

## Kustomize Layout

- deploy/k8s/base/namespace.yaml : namespace definition for the "web" workload.
- deploy/k8s/base/serviceaccount.yaml : Kubernetes ServiceAccount with the Workload Identity annotation placeholder (iam.gke.io/gcp-service-account: PLACEHOLDER_GSA_EMAIL).
- deploy/k8s/base/deployment.yaml : hardened deployment with probes, resource requests/limits, and IMAGE_PLACEHOLDER so automation can swap in digests.
- deploy/k8s/base/service.yaml : ClusterIP service on port 80.
- deploy/k8s/base/gateway.yaml : Gateway using the gke-l7-global-external-managed GatewayClass.
- deploy/k8s/base/httproute.yaml : HTTPRoute routing traffic from the Gateway to the web service.
- deploy/k8s/overlays/staging : patches replicas (1), HTTPRoute hostname (staging.example.com), and the ServiceAccount annotation.
- deploy/k8s/overlays/prod : patches replicas (3), HTTPRoute hostname (app.example.com), and the ServiceAccount annotation.

The base manifests capture shared configuration; overlays provide environment-specific differences, including image substitution via the `images` stanza so the pipelines can inject digests.

## Gateway API

Kubernetes Gateway API (via the gke-l7-global-external-managed GatewayClass) is used instead of legacy Ingress. The Gateway listener routes HTTP traffic to the web Service through an HTTPRoute. Update the hostnames and add TLS configuration (certificate references) before rolling out to real domains.

## GitHub Actions Pipelines

Staging workflow (`.github/workflows/deploy-staging.yml`):

1. Trigger: push to `main`.
2. Authenticates to Google Cloud with Workload Identity Federation (`STAGING_WORKLOAD_IDENTITY_PROVIDER`, `STAGING_WORKLOAD_IDENTITY_SERVICE_ACCOUNT`).
3. Installs Trivy, Grype, Syft, and Cosign and reuses `scripts/container/supply-chain.sh` to build, scan, generate an SBOM, and sign the image.
4. Pushes the image to `STAGING_IMAGE_REPO` tagged with `github.sha`.
5. Resolves the pushed digest (sha256 only), rewrites `deploy/k8s/overlays/staging/kustomization.yaml` to set `IMAGE_REPO` plus the digest field, and patches the ServiceAccount annotation with `STAGING_RUNTIME_GSA_EMAIL`.
6. Fetches GKE credentials for `STAGING_GKE_CLUSTER` (in `STAGING_GKE_LOCATION`, project `STAGING_GCP_PROJECT_ID`), applies the overlay, and waits for rollout.
7. The `e2e-validation` job runs after a successful deploy: it resolves the Gateway external IP, exports `E2E_TARGET_URL=http://<ip>`, installs dependencies and Playwright browsers, executes `pnpm --filter @ai-dev-platform/web test:e2e`, and fails the workflow on regression.

Production workflow (`.github/workflows/deploy-production.yml`):

1. Trigger: push of tags matching `v*.*.*`.
2. Mirrors the staging workflow with production secrets (`PRODUCTION_*`).
3. Tags container images with `github.ref_name`, injects the production digest and ServiceAccount annotation, and applies `deploy/k8s/overlays/prod`.

Required GitHub secrets (store them as environment-scoped secrets):

- `STAGING_IMAGE_REPO`, `PRODUCTION_IMAGE_REPO`
- `STAGING_ARTIFACT_REGISTRY_HOST`, `PRODUCTION_ARTIFACT_REGISTRY_HOST`
- `STAGING_GCP_PROJECT_ID`, `PRODUCTION_GCP_PROJECT_ID`
- `STAGING_GKE_LOCATION`, `STAGING_GKE_CLUSTER`, `PRODUCTION_GKE_LOCATION`, `PRODUCTION_GKE_CLUSTER`
- `STAGING_WORKLOAD_IDENTITY_PROVIDER`, `PRODUCTION_WORKLOAD_IDENTITY_PROVIDER`
- `STAGING_WORKLOAD_IDENTITY_SERVICE_ACCOUNT`, `PRODUCTION_WORKLOAD_IDENTITY_SERVICE_ACCOUNT`
- `STAGING_RUNTIME_GSA_EMAIL`, `PRODUCTION_RUNTIME_GSA_EMAIL`

## Workload Identity Binding

Bind the Kubernetes ServiceAccount "web" to each environment's GSA:

```
gcloud iam service-accounts add-iam-policy-binding \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:<project>.svc.id.goog[web/web]" \
  <gsa-email>
```

After binding, grant IAM permissions (for example Secret Manager) to the GSA rather than node identities.

## Manual Deployments (Optional)

```
kustomize build deploy/k8s/overlays/staging | kubectl apply -f -
kustomize build deploy/k8s/overlays/prod | kubectl apply -f -
```

Ensure the overlays reference the desired image digest and runtime GSA before applying manually.

## Next Steps

- Replace `HOSTNAME_PLACEHOLDER`, `staging.example.com`, and `app.example.com` with real domains.
- Populate GitHub environment secrets and configure approvals for production.
- Provision supporting infrastructure (GKE Gateway controller, Artifact Registry, Workload Identity bindings) via Terraform or another automation tool.
