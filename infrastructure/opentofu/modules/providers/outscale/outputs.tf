# Provider Contract Outputs — see provider-contract.md

# Node private IPs
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for nic in outscale_nic.control_plane : tolist(nic.private_ips)[0].private_ip]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = outscale_vm.worker[*].private_ip
}

# Load Balancer DNS names (Outscale LBs expose a DNS name, not a raw IP)
output "k8s_lb_ip" {
  description = "DNS name of the Kubernetes API LB (6443)"
  value       = outscale_load_balancer.k8s.dns_name
}

output "app_lb_ip" {
  description = "DNS name of the App LB (80/443)"
  value       = outscale_load_balancer.app.dns_name
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = outscale_public_ip.bastion.public_ip
}
