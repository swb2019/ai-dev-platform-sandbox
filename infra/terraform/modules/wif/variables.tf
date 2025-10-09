variable "project_id" {
  description = "GCP project where the Workload Identity Pool and Provider are created."
  type        = string
}

variable "pool_id" {
  description = "Workload Identity Pool ID (short name)."
  type        = string
}

variable "pool_display_name" {
  description = "Optional display name for the Workload Identity Pool."
  type        = string
  default     = null
}

variable "pool_description" {
  description = "Optional description for the Workload Identity Pool."
  type        = string
  default     = null
}

variable "attribute_condition" {
  description = "CEL expression restricting which identities from the provider may authenticate."
  type        = string
}

variable "provider_id" {
  description = "Workload Identity Pool Provider ID (short name)."
  type        = string
}

variable "provider_display_name" {
  description = "Optional display name for the provider."
  type        = string
  default     = null
}

variable "provider_description" {
  description = "Optional description for the provider."
  type        = string
  default     = null
}

variable "issuer_uri" {
  description = "OIDC issuer URI for the identity provider."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "allowed_audiences" {
  description = "Allowed audiences for tokens issued by the identity provider."
  type        = list(string)
  default     = ["sts.googleapis.com"]
}

variable "attribute_mapping" {
  description = "Attribute mapping configuration for the provider."
  type        = map(string)
  default = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }
}
