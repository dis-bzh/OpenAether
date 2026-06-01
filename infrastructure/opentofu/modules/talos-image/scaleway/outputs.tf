output "image_name" {
  description = "Name of the created image (same in every zone; the cluster module looks it up via data.scaleway_instance_image)."
  value       = var.image_name
}

output "image_ids" {
  description = "Map of zone => Scaleway Instance Image ID."
  value       = { for z, img in scaleway_instance_image.talos : z => img.id }
}

output "zones" {
  description = "Zones the image was published into."
  value       = var.zones
}
