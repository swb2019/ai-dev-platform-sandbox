variable "project_id" {
  description = "GCP project ID for the Autopilot cluster."
  type        = string
}

variable "location" {
  description = "Regional location for the Autopilot cluster."
  type        = string
}

variable "cluster_name" {
  description = "Name of the Autopilot cluster."
  type        = string
}

variable "network" {
  description = "Self link of the VPC network to attach to the cluster."
  type        = string
}

variable "subnetwork" {
  description = "Self link of the subnetwork to attach to the cluster."
  type        = string
}

variable "cluster_secondary_range_name" {
  description = "Name of the secondary range for Pods."
  type        = string
}

variable "services_secondary_range_name" {
  description = "Name of the secondary range for Services."
  type        = string
}

variable "release_channel" {
  description = "GKE release channel for the Autopilot cluster."
  type        = string
  default     = "REGULAR"
  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], upper(var.release_channel))
    error_message = "release_channel must be RAPID, REGULAR, or STABLE."
  }
}

variable "gateway_api_channel" {
  description = "Gateway API channel to enable on the cluster."
  type        = string
  default     = "CHANNEL_STANDARD"
  validation {
    condition     = contains(["CHANNEL_STANDARD", "CHANNEL_DISABLED"], var.gateway_api_channel)
    error_message = "gateway_api_channel must be CHANNEL_STANDARD or CHANNEL_DISABLED."
  }
}

variable "deletion_protection" {
  description = "Enable deletion protection on the cluster."
  type        = bool
  default     = true
}

variable "cluster_labels" {
  description = "Labels applied to the cluster."
  type        = map(string)
  default     = {}
}

variable "maintenance_start_time" {
  description = "Optional start time (RFC3339) for recurrent maintenance window."
  type        = string
  default     = null
}

variable "maintenance_end_time" {
  description = "Optional end time (RFC3339) for recurrent maintenance window."
  type        = string
  default     = null
}

variable "maintenance_recurrence" {
  description = "Optional RRULE for the maintenance window recurrence."
  type        = string
  default     = null
}
