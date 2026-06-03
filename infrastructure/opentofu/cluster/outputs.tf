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
  value       = local.bastion_ip
}

output "bastion_user" {
  description = "Default SSH user of the bastion (root on Scaleway, ubuntu on OVH/Outscale)"
  value       = local.bastion_user
}

# --- Secrets (for backup/DR) ---

output "machine_secrets" {
  description = "Talos machine secrets (sensitive, for DR)"
  value       = module.talos.machine_secrets
  sensitive   = true
}

# --- Backup / DR targets (consumed by scripts/backup-state.sh) ---

output "backup_targets" {
  description = "Derived buckets + endpoints for the state and artifact backups (non-sensitive)."
  value = {
    provider                = local.active_provider
    state_bucket_primary    = local.state_bucket_primary
    state_bucket_replica    = local.state_bucket_replica
    state_key               = local.state_key
    artifact_bucket_primary = local.artifact_bucket_primary
    artifact_bucket_replica = local.artifact_bucket_replica
    primary_endpoint        = var.s3_primary_endpoint
    primary_region          = var.s3_primary_region
    replica_endpoint        = var.s3_replica_endpoint
    replica_region          = var.s3_replica_region
  }
}

# --- Operational Instructions ---

output "talos_access_commands" {
  description = "SSH tunnel commands to reach each Talos node's API (50000) via the bastion. CPs map to localhost 5000+i, workers to 5010+i — distinct ports so all tunnels coexist."
  value = merge(
    { for idx, ip in local.control_plane_ips : "cp-${idx}" => "ssh -q -i ~/.ssh/key -L ${50000 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &" },
    { for idx, ip in local.worker_ips : "worker-${idx}" => "ssh -q -i ~/.ssh/key -L ${50100 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &" },
  )
}

output "instructions" {
  description = "Operational instructions for multi-env two-phase bootstrap"
  value       = <<-EOT
    # ─── Cluster: ${var.cluster_name}-${var.environment} (${var.cluster_role}) on ${local.active_provider} ──────
    #
    # Phase 1: Infra Creation
    #   tofu apply -var-file=envs/<cluster>.tfvars
    #
    # Phase 2: Talos Bootstrap (Requires SSH tunnels via Bastion — one per node)
    #   1. Open tunnels (control planes -> localhost 5000+i):
    %{for idx, ip in local.control_plane_ips}#      ssh -q -i ~/.ssh/key -L ${50000 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &
    %{endfor}#      ... and workers -> localhost 5010+i:
    %{for idx, ip in local.worker_ips}#      ssh -q -i ~/.ssh/key -L ${50100 + idx}:${ip}:50000 ${local.bastion_user}@${local.bastion_ip} -N &
    %{endfor}#
    #   2. Bootstrap:
    #      tofu apply -var-file=envs/<cluster>.tfvars -var talos_bootstrap=true
    #
    # ─── Register as ArgoCD spoke (workload clusters only) ──────────
    #   task register-spoke CLUSTER=${var.cluster_name}-${var.environment} PROVIDER=${local.active_provider}
    #
    # ─── Cross-provider failover (2nd management on another cloud) ──
    #   task failover PROVIDER=ovh
  EOT
}
