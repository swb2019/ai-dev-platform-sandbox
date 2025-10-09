output "cluster_name" {
  description = "Name of the Autopilot cluster."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Location of the Autopilot cluster."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Endpoint of the Autopilot cluster."
  value       = google_container_cluster.this.endpoint
}

output "workload_identity_pool" {
  description = "Workload identity pool associated with the cluster."
  value       = try(google_container_cluster.this.workload_identity_config[0].workload_pool, null)
}

output "cluster_id" {
  description = "ID of the Autopilot cluster."
  value       = google_container_cluster.this.id
}
