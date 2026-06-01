output "schematic_id" {
  description = "Resolved Image Factory schematic ID (deterministic from schematic.yaml)."
  value       = local.schematic_id
}

output "image_name" {
  description = "Name of the image — set this as image_name in the cluster envs/*.tfvars."
  value       = local.image_name
}

output "image_ids" {
  description = "Map of zone => image ID for the active provider."
  value       = var.target_provider == "scaleway" ? one(module.scaleway[*].image_ids) : null
}
