output "enabled_services" {
  description = "List of GCP services enabled by the module."
  value       = sort([for s in google_project_service.enabled : s.service])
}

output "artifact_repository_id" {
  description = "ID of the Artifact Registry repository (if created)."
  value       = try(google_artifact_registry_repository.this[0].id, null)
}

output "artifact_repository_name" {
  description = "Resource name of the Artifact Registry repository (if created)."
  value       = try(google_artifact_registry_repository.this[0].name, null)
}
