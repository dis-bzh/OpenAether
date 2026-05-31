# ==============================================================================
# Operational Outputs
# ==============================================================================

# --- Cluster Identity ---

output "active_provider" {
  description = "Cloud provider used for this cluster"
  value       = local.active_provider
}

output "cluster_role" {
  description = "Role of this cluster (management or workload)"
  value       = var.cluster_role
}

# --- Cluster Access ---

output "k8s_lb_ip" {
  description = "Public IP (or DNS name) of the Kubernetes API LB (6443)"
  value       = local.k8s_lb_ip
}

output "app_lb_ip" {
  description = "Public IP (or DNS name) of the App LB (80/443)"
  value = coalesce(
    try(module.scw[0].app_lb_ip, null),
    try(module.ovh[0].app_lb_ip, null),
    try(module.outscale[0].app_lb_ip, null),
    "N/A"
  )
}

output "kubeconfig" {
  description = "Kubeconfig for kubectl access"
  value       = module.talos.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig for talosctl access"
  value       = module.talos.talosconfig
  sensitive   = true
}

# --- Node IPs ---

output "control_plane_private_ips" {
  description = "Private IPs of control plane nodes (Talos API reachable on 50000/TCP via bastion)"
  value       = local.control_plane_ips
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = local.worker_ips
}

# --- Bastion ---

output "bastion_ip" {
  description = "Public IP of the bastion host"
  value = coalesce(
    try(module.scw[0].bastion_ip, null),
    try(module.ovh[0].bastion_ip, null),
    try(module.outscale[0].bastion_ip, null),
    "N/A"
  )
}

# --- Secrets (for backup/DR) ---

output "machine_secrets" {
  description = "Talos machine secrets (sensitive, for DR)"
  value       = module.talos.machine_secrets
  sensitive   = true
}

# --- Operational Instructions ---

output "talos_access_commands" {
  description = "SSH Tunnel commands to access Talos nodes via bastion"
  value = {
    for idx, ip in local.control_plane_ips : "cp-${idx}" => "ssh -q -i ~/.ssh/key -L 50000:${ip}:50000 ubuntu@${coalesce(try(module.scw[0].bastion_ip, null), try(module.ovh[0].bastion_ip, null), try(module.outscale[0].bastion_ip, null), "<bastion-ip>")} -N &"
  }
}

output "instructions" {
  description = "Operational instructions for multi-env two-phase bootstrap"
  value       = <<-EOT
    # ─── Cluster: ${var.cluster_name}-${var.environment} (${var.cluster_role}) on ${local.active_provider} ──────
    #
    # Phase 1: Infra Creation
    #   tofu apply -var-file=envs/<cluster>.tfvars
    #
    # Phase 2: Talos Bootstrap (Requires SSH tunnel via Bastion)
    #   1. Open tunnels (one per control plane):
    %{for idx, ip in local.control_plane_ips}#      ssh -q -i ~/.ssh/key -L 5000${idx}:${ip}:50000 ubuntu@${coalesce(try(module.scw[0].bastion_ip, null), try(module.ovh[0].bastion_ip, null), try(module.outscale[0].bastion_ip, null), "<bastion-ip>")} -N &
    %{endfor}#
    #   2. Bootstrap:
    #      tofu apply -var-file=envs/<cluster>.tfvars -var talos_bootstrap=true
    #
    # ─── Register as ArgoCD spoke (workload clusters only) ──────────
    #   task register-spoke CLUSTER=${var.cluster_name}-${var.environment} PROVIDER=${local.active_provider}
    #
    # ─── DRP (rebuild management on another provider) ───────────────
    #   task drp PROVIDER=ovh
  EOT
}
