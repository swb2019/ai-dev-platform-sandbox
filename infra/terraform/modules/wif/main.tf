resource "google_iam_workload_identity_pool" "this" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = coalesce(var.pool_display_name, upper(var.pool_id))
  description               = var.pool_description
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.this.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = coalesce(var.provider_display_name, upper(var.provider_id))
  description                        = var.provider_description
  attribute_condition               = var.attribute_condition

  oidc {
    issuer_uri        = var.issuer_uri
    allowed_audiences = var.allowed_audiences
  }

  attribute_mapping = var.attribute_mapping
}
