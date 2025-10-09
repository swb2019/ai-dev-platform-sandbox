variable "project_id" {
  description = "GCP project ID where the network will be created."
  type        = string
}

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
}

variable "network_description" {
  description = "Optional description for the VPC network."
  type        = string
  default     = ""
}

variable "routing_mode" {
  description = "Routing mode for the VPC network."
  type        = string
  default     = "REGIONAL"
  validation {
    condition     = contains(["REGIONAL", "GLOBAL"], upper(var.routing_mode))
    error_message = "routing_mode must be either REGIONAL or GLOBAL."
  }
}

variable "subnets" {
  description = "List of subnet definitions to create inside the VPC."
  type = list(
    object({
      name                     = string
      ip_cidr_range            = string
      region                   = string
      private_ip_google_access = optional(bool, true)
      secondary_ip_ranges = optional(
        list(
          object({
            range_name    = string
            ip_cidr_range = string
          })
        ),
        []
      )
    })
  )
  validation {
    condition     = length(var.subnets) > 0
    error_message = "At least one subnet must be defined."
  }
}

variable "create_nat" {
  description = "Whether to create a Cloud Router and Cloud NAT for outbound connectivity."
  type        = bool
  default     = true
}

variable "nat_router_name" {
  description = "Optional name override for the Cloud Router."
  type        = string
  default     = null
}

variable "nat_router_region" {
  description = "Optional region override for the Cloud Router/NAT. Defaults to the region of the first subnet."
  type        = string
  default     = null
}

variable "nat_name" {
  description = "Optional name override for the Cloud NAT."
  type        = string
  default     = null
}

variable "nat_logging" {
  description = "Enable logging for Cloud NAT."
  type        = bool
  default     = false
}
