output "network_name" {
  description = "Name of the created VPC network."
  value       = google_compute_network.this.name
}

output "network_self_link" {
  description = "Self link of the created VPC network."
  value       = google_compute_network.this.self_link
}

output "subnetworks" {
  description = "Map of subnetworks keyed by subnet name."
  value = {
    for name, subnet in google_compute_subnetwork.this :
    name => {
      name          = subnet.name
      self_link     = subnet.self_link
      region        = subnet.region
      ip_cidr_range = subnet.ip_cidr_range
      secondary_ip_ranges = [for range in subnet.secondary_ip_range : {
        range_name    = range.range_name
        ip_cidr_range = range.ip_cidr_range
      }]
    }
  }
}

output "router_name" {
  description = "Name of the Cloud Router (if created)."
  value       = try(google_compute_router.this[0].name, null)
}

output "nat_name" {
  description = "Name of the Cloud NAT (if created)."
  value       = try(google_compute_router_nat.this[0].name, null)
}
