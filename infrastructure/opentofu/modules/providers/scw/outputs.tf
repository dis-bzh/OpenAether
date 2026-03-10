# Nodes no longer have public IPs - private only (via IPAM)
output "control_plane_private_ips" {
  value = [for ip in scaleway_ipam_ip.control_plane : ip.address]
}

output "worker_private_ips" {
  value = [for ip in scaleway_ipam_ip.worker : ip.address]
}

# Bastion public IP for SSH access
output "bastion_ip" {
  value = scaleway_instance_ip.bastion.address
}

# Machine configurations for native Talos provider resources
output "control_plane_machine_config" {
  value     = data.talos_machine_configuration.control_plane.machine_configuration
  sensitive = true
}

output "worker_machine_config" {
  value     = data.talos_machine_configuration.worker.machine_configuration
  sensitive = true
}
