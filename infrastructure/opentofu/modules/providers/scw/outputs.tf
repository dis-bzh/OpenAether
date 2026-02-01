# Nodes no longer have public IPs - private only
output "control_plane_private_ips" {
  value = [for s in scaleway_instance_server.control_plane : s.private_ips[0].address if length(s.private_ips) > 0]
}

output "worker_private_ips" {
  value = [for s in scaleway_instance_server.worker : s.private_ips[0].address if length(s.private_ips) > 0]
}

# Bastion public IP for SSH access
output "bastion_ip" {
  value = scaleway_instance_ip.bastion.address
}
