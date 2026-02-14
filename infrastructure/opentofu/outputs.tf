output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "machine_secrets" {
  value     = module.talos.machine_secrets
  sensitive = true
}


# Load Balancer IPs (cluster endpoints)
output "scaleway_ips" {
  value = try(module.scw[0].lb_ip, null)
}

output "ovh_ips" {
  value = try(module.ovh[0].lb_ip, null)
}

output "outscale_ips" {
  value = try(module.outscale[0].lb_ip, null)
}

# Bastion IPs for SSH access
output "bastion_ips" {
  value = {
    scaleway = try(module.scw[0].bastion_ip, null)
    ovh      = try(module.ovh[0].bastion_ip, null)
    outscale = try(module.outscale[0].bastion_ip, null)
  }
  description = "Public IPs of bastion hosts for SSH tunneling"
}

output "cluster_endpoint" {
  value = local.effective_endpoint
  description = "Public endpoint for Kubernetes API access (Load Balancer)"
}

output "bootstrap_node_ip" {
  value       = local.bootstrap_node
  description = "Private IP of the node used for bootstrap."
}

output "instructions" {
  value = <<EOT
1. The Talos bootstrap is auto-configured via inline manifests (Cilium CNI).
2. The Load Balancer should become healthy once Cilium starts.
3. Access your cluster via the Load Balancer IP using the generated 'kubeconfig'.
   Example: kubectl get nodes --kubeconfig kubeconfig
EOT
}
