# Infrastructure Foundation

## Overview

This repository uses Terraform to provision the core Google Cloud Platform (GCP) infrastructure that supports both staging and production environments. The design follows a modular layout so that shared building blocks (networking, clusters, and supporting services) can be composed per environment while keeping runtime isolation and independent state files.

## Directory Layout

```
infra/
  terraform/
    modules/
      gke/          # GKE Autopilot cluster with Gateway API + GMP
      network/      # VPC, subnet, and Cloud NAT configuration
      services/     # Required APIs and Artifact Registry
    envs/
      staging/      # Staging-specific module wiring + backend
      prod/         # Production-specific module wiring + backend
```

- Each environment keeps its own `backend.tf` that points at a distinct prefix inside the shared Terraform state bucket.
- Module sources are referenced relatively (`../../modules/...`) so they can be versioned together with the environment definitions.

## Terraform Modules

### `modules/network`

- Creates a custom VPC with at least one subnet per environment.
- Supports secondary ranges so GKE can run in VPC-native mode.
- Manages a Cloud Router and Cloud NAT for secure egress; NAT logging is toggled via module input.

### `modules/gke`

- Provisions a GKE Autopilot cluster (Shielded Nodes are enforced by the platform).
- Enables Workload Identity (`workload_pool = <project>.svc.id.goog`).
- Keeps vertical pod autoscaling enabled for Autopilot workloads.
- Enables Gateway API (`gateway_api_config` with `CHANNEL_STANDARD`).
- Enables Google Managed Prometheus through `monitoring_config.managed_prometheus`.

### `modules/services`

- Enables the baseline set of GCP APIs required by the platform.
- Creates a regional Artifact Registry (Docker) repository with environment-specific labels.

## Environment Composition

### Staging (`infra/terraform/envs/staging`)

- Prefixes resources with `stg`.
- Uses non-overlapping CIDR ranges within `10.20.0.0/20` for the primary subnet, plus secondary ranges for Pods (`10.20.16.0/20`) and Services (`10.20.32.0/24`).
- Sets the Artifact Registry to the staging region and labels resources with `environment = staging`.

### Production (`infra/terraform/envs/prod`)

- Prefixes resources with `prd`.
- Allocates 10.40.0.0/20 (primary), 10.40.16.0/20 (Pods), and 10.40.32.0/24 (Services).
- Enables the same module features as staging but defaults the cluster release channel to `STABLE` and descriptions to “production”.

### Backend Isolation

- Both environments reference the same GCS bucket but use unique prefixes (`state/staging` vs `state/prod`).
- The bootstrap script replaces the placeholder bucket value in each `backend.tf` so Terraform can initialize without manual edits.

## Bootstrap Workflow

Run `scripts/bootstrap-infra.sh` to perform the initial bootstrap.

1. **Collect config:** prompts for GCP project, region, GitHub repo, and Terraform state bucket name. Values are saved in `.infra_bootstrap_state` for reuse.
2. **CLI checks:** validates `gcloud`, `gh`, and `terraform` availability and authentication.
3. **Enable APIs:** ensures the required GCP services—Compute, GKE, Artifact Registry, Certificate Manager, etc.—are enabled.
4. **Terraform backend:** creates (or confirms) the GCS bucket, enables versioning, and updates both `backend.tf` files with the actual bucket name.
5. **Initial provisioning:** runs `terraform init` (always) and offers an interactive `terraform apply` for `staging` and `prod`. Skipped applies are recorded and reported at the end.

## Day-2 Operations

- To reconfigure the backend or rerun Terraform, execute `scripts/bootstrap-infra.sh` again; the script reads existing values and only reapplies what is needed.
- For manual Terraform work, change into `infra/terraform/envs/<env>` and run `terraform plan` / `apply`. The configured backend will reuse the shared GCS bucket with the environment-specific prefix.
- Update module variables (for example, CIDR ranges or labels) in the environment `main.tf` files and reapply through Terraform.

## Security & Compliance Notes

- Cloud NAT logging is enabled by default; adjust via the `nat_logging` variable in each environment if cost controls require it.
- Artifact Registry inherits uniform bucket-level access and labels for traceability.
- Gateway API and Managed Prometheus are enabled per Google’s recommended settings for modern service routing and observability.
