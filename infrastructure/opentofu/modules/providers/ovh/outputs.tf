output "control_plane_public_ips" {
  value = openstack_compute_instance_v2.control_plane[*].access_ip_v4
}

output "control_plane_private_ips" {
  value = openstack_compute_instance_v2.control_plane[*].access_ip_v4 # On Ext-Net, often same as public
}

output "worker_public_ips" {
  value = openstack_compute_instance_v2.worker[*].access_ip_v4
}

output "worker_private_ips" {
  value = openstack_compute_instance_v2.worker[*].access_ip_v4
}

