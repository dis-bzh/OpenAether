output "machine_secrets" {
  description = "Talos machine secrets (for backup and DR)"
  value       = talos_machine_secrets.this.machine_secrets
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client config file content (talosconfig)"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig_raw" {
  description = "Raw kubeconfig content for kubectl access"
  value       = var.control_plane_count > 0 ? talos_cluster_kubeconfig.this[0].kubeconfig_raw : ""
  sensitive   = true
}

output "control_plane_config" {
  description = "Control plane machine configuration (for backup)"
  value       = length(data.talos_machine_configuration.control_plane) > 0 ? data.talos_machine_configuration.control_plane[0].machine_configuration : null
  sensitive   = true
}

output "worker_config" {
  description = "Worker machine configuration (for backup)"
  value       = length(data.talos_machine_configuration.worker) > 0 ? data.talos_machine_configuration.worker[0].machine_configuration : null
  sensitive   = true
}
