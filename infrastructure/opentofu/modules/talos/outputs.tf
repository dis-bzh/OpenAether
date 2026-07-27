output "machine_secrets" {
  description = "Talos machine secrets (for backup and DR)"
  value       = local.machine_secrets.machine_secrets
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = local.machine_secrets.client_configuration
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

output "apiserver_vip" {
  description = "Talos Layer2 VIP configured on the control plane interface, if any"
  value       = var.apiserver_vip
}

output "bootstrap_manifests_enabled" {
  description = "Whether bootstrap manifests (Flux) are injected via inlineManifests"
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

# Rattache `data.talos_cluster_health` au graphe.
#
# Il n'est plus référencé par `talos_cluster_kubeconfig` (cf. le commentaire là-bas :
# il expire sur des clusters SAINS et faisait alors perdre kubeconfig ET
# talosconfig). Un data source non référencé est tout de même évalué à chaque
# plan/apply — son expiration fait donc toujours échouer l'apply, le signal est
# conservé — mais tflint le signale à juste titre comme orphelin. Cet output le
# rattache explicitement ET rend l'état visible à l'opérateur.
output "cluster_health" {
  description = "État de la vérification de santé Talos : 'skipped' (skip_health_check) ou 'verified'."
  value       = var.skip_health_check ? "skipped" : (length(data.talos_cluster_health.this) > 0 ? "verified" : "n/a")
}
