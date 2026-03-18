# ==============================================================================
# Operational Outputs
# ==============================================================================

# --- Cluster Access ---

output "k8s_lb_ip" {
  description = "Public IP of the Kubernetes API LB (6443)"
  value       = local.k8s_lb_ip
}

output "app_lb_ip" {
  description = "Public IP of the App LB (80/443)"
  value       = try(module.scw[0].app_lb_ip, null)
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
  value       = try(module.scw[0].bastion_ip, null)
}

# --- Secrets (for backup/DR) ---

output "machine_secrets" {
  description = "Talos machine secrets (sensitive, for DR)"
  value       = module.talos.machine_secrets
  sensitive   = true
}

# --- Operational Instructions ---

output "instructions" {
  description = "Post-deployment access instructions"
  value       = <<-EOT
    # ─── Access ───────────────────────────────────────────
    # Kubernetes API:
    #   export KUBECONFIG=./kubeconfig
    #   kubectl get nodes

    # ─── Talos API (via bastion tunnel) ───────────────────
    #   ssh -i ~/.ssh/key \
    #     -L 50000:${try(local.control_plane_ips[0], "<cp0-ip>")}:50000 \
    #     ubuntu@${try(module.scw[0].bastion_ip, "<bastion-ip>")} -N &
    #
    #   export TALOSCONFIG=./talosconfig
    #   talosctl --endpoints 127.0.0.1 health

    # ─── Day 1 (re-apply) ────────────────────────────────
    #   tofu apply     # Should be no-op

    # ─── Day 2 (upgrades) ────────────────────────────────
    #   # Update bootstrap-manifests/ with new versions
    #   ./scripts/render-bootstrap-manifests.sh
    #   tofu apply     # New configs applied to nodes
  EOT
}
