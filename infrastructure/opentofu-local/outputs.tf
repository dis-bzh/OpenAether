output "control_plane_count" {
  value = local.cp_count
}

output "control_plane_ips" {
  description = "Control plane node identity IPs (Docker network)"
  value       = local.cp_ips
}

output "control_plane_endpoints" {
  description = "Host-reachable Talos API endpoints"
  value       = local.cp_endpoints
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "k8s_api_host_endpoint" {
  description = "Host-reachable Kubernetes API"
  value       = module.local.k8s_api_host_endpoint
}

output "talosconfig_path" {
  value = "${path.module}/talosconfig"
}

output "kubeconfig_path" {
  value = var.talos_bootstrap ? "${path.module}/kubeconfig" : "not generated (talos_bootstrap=false)"
}

output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = var.talos_bootstrap ? module.talos.kubeconfig_raw : ""
  sensitive = true
}
