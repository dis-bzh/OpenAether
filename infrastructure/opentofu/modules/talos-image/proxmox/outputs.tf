output "image_file_id" {
  description = "Proxmox file_id for the downloaded Talos image (datastore:iso/filename). Matches the convention cluster/main.tf falls back to when talos_image_file_id is left unset, so it rarely needs to be set explicitly in the cluster envs/*.tfvars."
  value       = "${var.iso_datastore_id}:iso/${local.file_name}"
}

output "image_name" {
  description = "Bare file name of the downloaded image (without the datastore:iso/ prefix)."
  value       = local.file_name
}
