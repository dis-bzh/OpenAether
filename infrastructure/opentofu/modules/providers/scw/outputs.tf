# Node private IPs (via IPAM)
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for ip in scaleway_ipam_ip.control_plane : ip.address]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = [for ip in scaleway_ipam_ip.worker : ip.address]
}

# Load Balancer IPs
output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443)"
  value       = scaleway_lb_ip.k8s.ip_address
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443)"
  value       = scaleway_lb_ip.app.ip_address
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = scaleway_instance_ip.bastion.address
}
