variable "project_id" {
  description = "GCP project ID to enable services in."
  type        = string
}

variable "services" {
  description = "List of services (APIs) to enable in the project."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "binaryauthorization.googleapis.com",
    "serviceusage.googleapis.com",
    "certificatemanager.googleapis.com",
    "mesh.googleapis.com"
  ]
}

variable "location" {
  description = "Region for the Artifact Registry repository."
  type        = string
}

variable "repository_id" {
  description = "ID (name) for the Artifact Registry repository."
  type        = string
}

variable "repository_format" {
  description = "Artifact Registry format."
  type        = string
  default     = "DOCKER"
  validation {
    condition     = contains(["DOCKER", "MAVEN", "NPM", "PYTHON", "APT", "YUM", "GO", "KFP", "GENERIC"], upper(var.repository_format))
    error_message = "repository_format must be a valid Artifact Registry format."
  }
}

variable "repository_description" {
  description = "Optional description for the Artifact Registry repository."
  type        = string
  default     = "Container images"
}

variable "repository_labels" {
  description = "Labels to apply to the Artifact Registry repository."
  type        = map(string)
  default     = {}
}

variable "create_repository" {
  description = "Whether to create the Artifact Registry repository."
  type        = bool
  default     = true
}
