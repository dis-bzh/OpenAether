output "control_plane_private_ips" {
  value = outscale_vm.control_plane[*].private_ip
}

output "worker_private_ips" {
  value = outscale_vm.worker[*].private_ip
}

output "bastion_ip" {
  value = outscale_public_ip.bastion.public_ip
}

