# Provider Contract Outputs — see provider-contract.md

# Node private IPs
output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes"
  value       = [for p in openstack_networking_port_v2.control_plane : try(p.all_fixed_ips[0], "")]
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = openstack_compute_instance_v2.worker[*].access_ip_v4
}

# Load Balancer IPs (floating IPs)
output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443)"
  value       = openstack_networking_floatingip_v2.k8s.address
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443)"
  value       = openstack_networking_floatingip_v2.app.address
}

# Bastion
output "bastion_ip" {
  description = "Public IP of the bastion host (SSH access)"
  value       = openstack_networking_floatingip_v2.bastion.address
}
