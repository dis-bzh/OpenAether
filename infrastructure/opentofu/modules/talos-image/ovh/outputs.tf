output "image_id" {
  description = "Glance image UUID — set this as image_id in the cluster envs/*.tfvars (OVH)."
  value       = openstack_images_image_v2.talos.id
}

output "image_name" {
  description = "Name of the created Glance image."
  value       = var.image_name
}
