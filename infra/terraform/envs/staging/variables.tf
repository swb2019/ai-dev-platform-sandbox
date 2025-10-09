variable "project_id" {
  description = "GCP project ID for the staging environment."
  type        = string
}

variable "region" {
  description = "Default region for staging resources."
  type        = string
  default     = "us-central1"
}

variable "gke_location" {
  description = "Optional override for the GKE Autopilot location. Defaults to the region."
  type        = string
  default     = null
}

variable "artifact_registry_location" {
  description = "Optional override for the Artifact Registry location. Defaults to the region."
  type        = string
  default     = null
}

variable "common_labels" {
  description = "Labels applied to all staging resources."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Whether to enable deletion protection on critical resources."
  type        = bool
  default     = true
}

variable "nat_logging" {
  description = "Enable Cloud NAT logging in staging."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the Terraform identity."
  type        = string
}

variable "runtime_service_account_namespace" {
  description = "Kubernetes namespace of the service account using Workload Identity."
  type        = string
}

variable "runtime_service_account_name" {
  description = "Kubernetes service account name using Workload Identity."
  type        = string
}

variable "terraform_admin_roles" {
  description = "IAM roles granted to the Terraform service account."
  type        = list(string)
  default = [
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/artifactregistry.admin",
    "roles/storage.admin"
  ]
}

variable "runtime_service_account_roles" {
  description = "IAM roles granted to the runtime service account."
  type        = list(string)
  default = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/artifactregistry.reader"
  ]
}

variable "binary_authorization_attestors" {
  description = "Binary Authorization attestor resource names (e.g. projects/<project>/attestors/<name>) required for image promotion."
  type        = list(string)
  validation {
    condition     = length(var.binary_authorization_attestors) > 0
    error_message = "At least one Binary Authorization attestor must be provided."
  }
}

variable "binary_authorization_whitelist_patterns" {
  description = "Image name patterns exempted from Binary Authorization attestation checks."
  type        = list(string)
  default = [
    "gcr.io/google_containers/*",
    "gke.gcr.io/*",
    "k8s.gcr.io/*"
  ]
}
