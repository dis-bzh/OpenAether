output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "machine_secrets" {
  value     = module.talos.machine_secrets
  sensitive = true
}

output "control_plane_machine_config" {
  value     = module.talos.controlplane_machine_config
  sensitive = true
}

output "worker_machine_config" {
  value     = module.talos.worker_machine_config
  sensitive = true
}

# Load Balancer IPs (cluster endpoints)
output "scaleway_ips" {
  value = try(module.scw[0].lb_ip, null)
}

output "ovh_ips" {
  value = try(module.ovh[0].lb_ip, null)
}

output "outscale_ips" {
  value = try(module.outscale[0].lb_ip, null)
}

# Bastion IPs for SSH access
output "bastion_ips" {
  value = {
    scaleway = try(module.scw[0].bastion_ip, null)
    ovh      = try(module.ovh[0].bastion_ip, null)
    outscale = try(module.outscale[0].bastion_ip, null)
  }
  description = "Public IPs of bastion hosts for SSH tunneling"
}

# Cluster endpoint (Load Balancer IP)
output "cluster_endpoint" {
  value = coalesce(
    try(module.scw[0].lb_ip, null),
    try(module.ovh[0].lb_ip, null),
    try(module.outscale[0].lb_ip, null),
    "no-lb-provisioned"
  )
  description = "Public endpoint for Kubernetes API access"
}
