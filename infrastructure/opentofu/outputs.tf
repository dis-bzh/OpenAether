output "talosconfig" {
  value     = module.talos.talosconfig
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
  value = local.effective_endpoint # Use local defined in main.tf or same logic
  description = "Public endpoint for Kubernetes API access (Load Balancer)"
}

output "bootstrap_node_ip" {
  value       = local.bootstrap_node
  description = "Private IP of the node used for bootstrap. Access via tunnel/sshtunnel for initial bootstrap."
}

output "instructions" {
  value = <<EOT
1. Ensure you have network access to the private IPs (e.g. via sshtunnel through the bastion).
2. The Talos bootstrap has been initiated via the provider.
3. Use the local 'talosconfig' and 'kubeconfig' files to manage your cluster.
   Example: talosctl --talosconfig talosconfig Health --nodes ${local.bootstrap_node}
EOT
}
