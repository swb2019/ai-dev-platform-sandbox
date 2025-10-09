locals {
  environment                   = "production"
  name_prefix                   = "prd"
  region                        = var.region
  gke_location                  = coalesce(var.gke_location, var.region)
  artifact_location             = coalesce(var.artifact_registry_location, var.region)
  pods_secondary_range_name     = "${local.name_prefix}-pods"
  services_secondary_range_name = "${local.name_prefix}-services"
  primary_subnet = {
    name          = "${local.name_prefix}-primary"
    ip_cidr_range = "10.40.0.0/20"
    region        = var.region
    secondary_ip_ranges = [
      {
        range_name    = local.pods_secondary_range_name
        ip_cidr_range = "10.40.16.0/20"
      },
      {
        range_name    = local.services_secondary_range_name
        ip_cidr_range = "10.40.32.0/24"
      }
    ]
  }
  base_labels = merge({
    environment = local.environment
  }, var.common_labels)

  terraform_service_account_id = "${local.name_prefix}-tf-admin"
  runtime_service_account_id   = "${local.name_prefix}-runtime"
  terraform_roles              = var.terraform_admin_roles
  runtime_roles                = var.runtime_service_account_roles
}

module "services" {
  source                 = "../../modules/services"
  project_id             = var.project_id
  location               = local.artifact_location
  repository_id          = "${local.name_prefix}-docker"
  repository_description = "Production container images"
  repository_labels      = local.base_labels
}

module "network" {
  source              = "../../modules/network"
  project_id          = var.project_id
  network_name        = "${local.name_prefix}-core-vpc"
  network_description = "Production core VPC"
  routing_mode        = "REGIONAL"
  subnets             = [local.primary_subnet]
  create_nat          = true
  nat_logging         = var.nat_logging
  nat_router_region   = local.region
}

module "wif" {
  source                = "../../modules/wif"
  project_id            = var.project_id
  pool_id               = "${local.name_prefix}-github"
  pool_display_name     = "Production GitHub WIF Pool"
  pool_description      = "GitHub OIDC federation for production infrastructure"
  provider_id           = "${local.name_prefix}-gha"
  provider_display_name = "Production GitHub OIDC"
  provider_description  = "GitHub Actions provider for production"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }
  attribute_condition = <<-EOT
    assertion.repository == "${var.github_repository}" && (
      assertion.ref == "refs/heads/main" ||
      assertion.ref.startsWith("refs/pull/") ||
      assertion.event_name == "pull_request"
    )
  EOT
}


resource "google_binary_authorization_policy" "this" {
  project = var.project_id

  dynamic "admission_whitelist_patterns" {
    for_each = var.binary_authorization_whitelist_patterns
    content {
      name_pattern = admission_whitelist_patterns.value
    }
  }

  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = var.binary_authorization_attestors
  }

  global_policy_evaluation_mode = "ENABLE"
}

resource "google_service_account" "terraform" {
  account_id   = local.terraform_service_account_id
  display_name = "Production Terraform Admin"
}

resource "google_service_account" "runtime" {
  account_id   = local.runtime_service_account_id
  display_name = "Production Runtime"
}

resource "google_project_iam_member" "terraform_roles" {
  for_each = toset(local.terraform_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.terraform.email}"
}

resource "google_project_iam_member" "runtime_roles" {
  for_each = toset(local.runtime_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_service_account_iam_member" "terraform_wif" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${module.wif.workload_identity_pool_name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "runtime_workload_identity" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.runtime_service_account_namespace}/${var.runtime_service_account_name}]"
}

module "gke" {
  source                        = "../../modules/gke"
  project_id                    = var.project_id
  location                      = local.gke_location
  cluster_name                  = "${local.name_prefix}-autopilot"
  network                       = module.network.network_self_link
  subnetwork                    = module.network.subnetworks[local.primary_subnet.name].self_link
  cluster_secondary_range_name  = local.pods_secondary_range_name
  services_secondary_range_name = local.services_secondary_range_name
  release_channel               = "STABLE"
  gateway_api_channel           = "CHANNEL_STANDARD"
  deletion_protection           = var.deletion_protection
  cluster_labels                = local.base_labels

  depends_on = [module.services, google_binary_authorization_policy.this]
}
