locals {
  maintenance_enabled = (
    var.maintenance_start_time != null &&
    var.maintenance_end_time != null &&
    var.maintenance_recurrence != null
  )
}

resource "google_container_cluster" "this" {
  provider = google-beta
  project  = var.project_id
  name     = var.cluster_name
  location = var.location

  enable_autopilot = true
  # Shielded Nodes are enforced automatically for Autopilot clusters.
  deletion_protection = var.deletion_protection
  networking_mode     = "VPC_NATIVE"
  network             = var.network
  subnetwork          = var.subnetwork
  resource_labels     = var.cluster_labels

  release_channel {
    channel = upper(var.release_channel)
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.cluster_secondary_range_name
    services_secondary_range_name = var.services_secondary_range_name
  }

  gateway_api_config {
    channel = var.gateway_api_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS"
    ]
    managed_prometheus {
      enabled = true
    }
  }

  vertical_pod_autoscaling {
    enabled = true
  }

  dynamic "maintenance_policy" {
    for_each = local.maintenance_enabled ? [1] : []
    content {
      recurring_window {
        start_time = var.maintenance_start_time
        end_time   = var.maintenance_end_time
        recurrence = var.maintenance_recurrence
      }
    }
  }
}
