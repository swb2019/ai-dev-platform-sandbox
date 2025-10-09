output "workload_identity_pool_id" {
  description = "Workload Identity Pool ID (short name)."
  value       = google_iam_workload_identity_pool.this.workload_identity_pool_id
}

output "workload_identity_pool_name" {
  description = "Full resource name of the Workload Identity Pool."
  value       = google_iam_workload_identity_pool.this.name
}

output "workload_identity_pool_provider_id" {
  description = "Provider ID (short name)."
  value       = google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id
}

output "workload_identity_pool_provider_name" {
  description = "Full resource name of the Workload Identity Pool Provider."
  value       = google_iam_workload_identity_pool_provider.github.name
}
