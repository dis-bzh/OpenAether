output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "machine_secrets" {
  value     = module.talos.machine_secrets
  sensitive = true
}

# LB IPs
output "app_lb_ip" {
  value       = try(module.scw[0].app_lb_ip, null)
  description = "Public IP of the permanent App LB (80/443)"
}

output "admin_lb_ip" {
  value       = try(module.scw[0].admin_lb_ip, null)
  description = "Public IP of the ephemeral Admin LB (6443/50000). Null when disabled."
}

# Bastion IPs for SSH access
output "bastion_ips" {
  value = {
    scaleway = try(module.scw[0].bastion_ip, null)
    ovh      = try(module.ovh[0].bastion_ip, null)
    outscale = try(module.outscale[0].bastion_ip, null)
  }
  description = "Public IPs of bastion hosts"
}

output "bootstrap_node_ip" {
  value       = local.bootstrap_node_ip
  description = "Private IP of the node used for bootstrap"
}

output "instructions" {
  value = <<EOT
# Bootstrap (Day 0):
  tofu apply -var 'admin_lb_enabled=true'

# After bootstrap, remove helm releases from state (ArgoCD takes over):
  tofu state rm 'helm_release.cilium[0]' 'helm_release.argocd[0]'
  tofu apply -var 'admin_lb_enabled=false'

# Maintenance (Day N):
  tofu apply -var 'admin_lb_enabled=true'
  kubectl --kubeconfig=./kubeconfig get nodes
  tofu apply -var 'admin_lb_enabled=false'
EOT
}
