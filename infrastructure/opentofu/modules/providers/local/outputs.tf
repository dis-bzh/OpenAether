# Provider Contract Outputs — see provider-contract.md
#
# Node identity IPs are the Docker static IPs (10.5.0.x) — used for etcd/certSANs.
# Endpoints are the 127.0.0.1 port mappings the Talos provider connects through
# (container IPs aren't routable from the WSL2 host with Docker Desktop).

output "control_plane_private_ips" {
  description = "Control plane node identity IPs (Docker static IPs)"
  value       = local.cp_ips
}

output "worker_private_ips" {
  description = "Worker node identity IPs (Docker static IPs)"
  value       = local.worker_ips
}

output "control_plane_endpoints" {
  description = "Host-reachable Talos API endpoints (127.0.0.1:port per CP)"
  value       = [for p in local.cp_ports : "127.0.0.1:${p}"]
}

output "worker_endpoints" {
  description = "Host-reachable Talos API endpoints for workers"
  value       = [for p in local.worker_ports : "127.0.0.1:${p}"]
}

output "k8s_lb_ip" {
  description = "Control plane 0 IP — used as the cluster endpoint (no LB locally)"
  value       = length(local.cp_ips) > 0 ? local.cp_ips[0] : "127.0.0.1"
}

output "k8s_api_host_endpoint" {
  description = "Host-reachable Kubernetes API (for rewriting kubeconfig)"
  value       = "https://127.0.0.1:${var.k8s_api_port}"
}

output "bastion_ip" {
  description = "No bastion for local — direct localhost access"
  value       = "127.0.0.1"
}

output "app_lb_ip" {
  description = "No app LB for local"
  value       = "127.0.0.1"
}

output "container_names" {
  description = "Names of the control plane containers"
  value       = local.cp_names
}
