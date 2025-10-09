resource "google_project_service" "enabled" {
  for_each                   = toset(var.services)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_artifact_registry_repository" "this" {
  count         = var.create_repository ? 1 : 0
  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  format        = upper(var.repository_format)
  description   = var.repository_description
  labels        = var.repository_labels
  mode          = "STANDARD_REPOSITORY"

  depends_on = [google_project_service.enabled]
}
