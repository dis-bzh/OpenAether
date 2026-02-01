output "control_plane_public_ips" {
  value = outscale_public_ip.control_plane[*].public_ip
}

output "control_plane_private_ips" {
  value = outscale_vm.control_plane[*].private_ip
}

output "worker_public_ips" {
  value = outscale_public_ip.worker[*].public_ip
}

output "worker_private_ips" {
  value = outscale_vm.worker[*].private_ip
}

