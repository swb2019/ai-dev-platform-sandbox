output "network_name" {
  description = "Name of the staging VPC network."
  value       = module.network.network_name
}

output "cluster_name" {
  description = "Name of the staging GKE Autopilot cluster."
  value       = module.gke.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the staging GKE Autopilot cluster."
  value       = module.gke.endpoint
}

output "gke_location" {
  description = "Location of the staging GKE Autopilot cluster."
  value       = module.gke.cluster_location
}

output "artifact_registry_repository" {
  description = "Artifact Registry repository resource name for staging."
  value       = module.services.artifact_repository_name
}

output "terraform_service_account_email" {
  description = "Email of the Terraform service account for staging."
  value       = google_service_account.terraform.email
}

output "runtime_service_account_email" {
  description = "Email of the runtime service account for staging workloads."
  value       = google_service_account.runtime.email
}

output "wif_provider_id" {
  description = "Short ID of the GitHub Workload Identity Provider for staging."
  value       = module.wif.workload_identity_pool_provider_id
}

output "wif_provider_name" {
  description = "Full resource name of the GitHub Workload Identity Provider for staging."
  value       = module.wif.workload_identity_pool_provider_name
}

output "wif_pool_name" {
  description = "Full resource name of the Workload Identity Pool for staging."
  value       = module.wif.workload_identity_pool_name
}
