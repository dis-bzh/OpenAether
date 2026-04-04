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

output "talos_access_commands" {
  description = "SSH Tunnel commands to access Talos nodes"
  value = {
    for idx, ip in local.control_plane_ips : "cp-${idx}" => "ssh -q -i ~/.ssh/key -L 50000:${ip}:50000 ubuntu@${try(module.scw[0].bastion_ip, "<bastion-ip>")} -N &"
  }
}

output "instructions" {
  description = "Operational instructions for multi-env two-phase bootstrap"
  value       = <<-EOT
    # ─── Multi-Env Two-Phase Bootstrap ──────────────────────────────
    #
    # Phase 1: Infra Creation (No Talos Config)
    #   tofu apply -var-file=envs/dev.tfvars
    #
    # Phase 2: Talos Configuration & Bootstrap (Requires Tunnel)
    #   1. Establish SSH tunnel(s) via the Bastion:
%{for idx, ip in local.control_plane_ips}    #      ssh -q -i ~/.ssh/key -L 50000:${ip}:50000 ubuntu@${try(module.scw[0].bastion_ip, "<bastion-ip>")} -N &
%{endfor}
    #   2. Apply with Talos enabled:
    #      tofu apply -var-file=envs/dev.tfvars -var talos_bootstrap=true
    #
    # ─── Access ──────────────────────────────────────────────────
    # Kubernetes API (Day 1+):
    #   export KUBECONFIG=./kubeconfig
    #   kubectl get nodes
    #
    # Talos API:
    #   export TALOSCONFIG=./talosconfig
    #   talosctl --endpoints 127.0.0.1 health
    #
    # ─── Day 1+ Operations ─────────────────────────────────────────
    #   tofu apply -var-file=envs/dev.tfvars -var talos_bootstrap=true
  EOT
}
