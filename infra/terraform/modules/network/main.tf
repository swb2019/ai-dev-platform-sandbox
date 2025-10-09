locals {
  primary_subnet_region = length(var.subnets) > 0 ? var.subnets[0].region : null
  nat_router_region     = coalesce(var.nat_router_region, local.primary_subnet_region)
  nat_router_name       = coalesce(var.nat_router_name, "${var.network_name}-router")
  nat_name              = coalesce(var.nat_name, "${var.network_name}-nat")
}

resource "google_compute_network" "this" {
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
  description             = var.network_description
  routing_mode            = upper(var.routing_mode)
}

resource "google_compute_subnetwork" "this" {
  for_each                 = { for subnet in var.subnets : subnet.name => subnet }
  project                  = var.project_id
  name                     = each.value.name
  ip_cidr_range            = each.value.ip_cidr_range
  region                   = each.value.region
  network                  = google_compute_network.this.id
  private_ip_google_access = try(each.value.private_ip_google_access, true)

  dynamic "secondary_ip_range" {
    for_each = try(each.value.secondary_ip_ranges, [])
    content {
      range_name    = secondary_ip_range.value.range_name
      ip_cidr_range = secondary_ip_range.value.ip_cidr_range
    }
  }
}

resource "google_compute_router" "this" {
  count   = var.create_nat ? 1 : 0
  name    = local.nat_router_name
  project = var.project_id
  region  = local.nat_router_region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count   = var.create_nat ? 1 : 0
  name    = local.nat_name
  project = var.project_id
  region  = local.nat_router_region
  router  = google_compute_router.this[0].name

  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_endpoint_independent_mapping = true

  log_config {
    enable = var.nat_logging
    filter = "ERRORS_ONLY"
  }
}
