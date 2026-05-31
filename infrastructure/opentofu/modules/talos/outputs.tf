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

# Expose for testing and observability
output "cluster_endpoint" {
  description = "Kubernetes API cluster endpoint (https://<lb_ip>:6443)"
  value       = var.cluster_endpoint
}

output "bootstrap_manifests_enabled" {
  description = "Whether bootstrap manifests (ArgoCD) are injected via inlineManifests"
  value       = var.bootstrap_manifests_enabled
}

output "control_plane_count" {
  description = "Number of control plane nodes configured"
  value       = var.control_plane_count
}

# Per-node generated machine configs — consumed by the provider module to inject
# via USERDATA when config_delivery = "userdata" (Docker/container platforms).
output "control_plane_machine_configs" {
  description = "Generated control plane machine configurations (one per node)"
  value       = [for c in data.talos_machine_configuration.control_plane : c.machine_configuration]
  sensitive   = true
}

output "worker_machine_configs" {
  description = "Generated worker machine configurations (one per node)"
  value       = [for c in data.talos_machine_configuration.worker : c.machine_configuration]
  sensitive   = true
}
