provider "talos" {}

# ==============================================================================
# Local 3-CP Talos cluster on Docker — exercises the PRODUCTION modules/talos
# (config generation, bootstrap, health, kubeconfig) with config_delivery=userdata.
#
# Node IPs and endpoints are deterministic (computed from static inputs), so we
# derive them in the root and feed modules/talos. This avoids a module cycle:
#   modules/talos (config) → modules/providers/local (containers via USERDATA)
# while modules/talos.bootstrap reaches nodes via the static 127.0.0.1 endpoints
# (retrying until the containers are up).
# ==============================================================================

locals {
  net_prefix       = "10.5.0"
  cp_count         = var.control_plane_count
  cp_ips           = [for i in range(local.cp_count) : "${local.net_prefix}.${10 + i}"]
  cp_endpoints     = [for i in range(local.cp_count) : "127.0.0.1:${50000 + i}"]
  cluster_endpoint = "https://${local.cp_ips[0]}:6443" # cp0 is the API endpoint (no LB locally)

  manifests_dir = "${path.module}/../opentofu/bootstrap-manifests"
  cilium_manifest = var.cilium_manifest != null ? var.cilium_manifest : (
    fileexists("${local.manifests_dir}/cilium-local.yaml")
    ? file("${local.manifests_dir}/cilium-local.yaml")
    : file("${local.manifests_dir}/cilium.yaml")
  )
}

# ==============================================================================
# Talos — secrets, config generation, bootstrap, health, kubeconfig
# (the real production module; only config delivery differs from cloud)
# ==============================================================================

module "talos" {
  source = "../opentofu/modules/talos"

  cluster_name       = "${var.cluster_name}-${var.environment}"
  cluster_endpoint   = local.cluster_endpoint
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  control_plane_count = var.talos_bootstrap ? local.cp_count : 0
  worker_count        = 0

  control_plane_ips       = local.cp_ips
  worker_ips              = []
  control_plane_endpoints = local.cp_endpoints
  k8s_lb_ip               = local.cp_ips[0]

  # Container/Docker specifics
  container_mode  = true
  config_delivery = "userdata"

  # The talos_cluster_health data source stalls behind WSL2/Docker port mappings;
  # the local test verifies health out-of-band via `talosctl health` instead.
  skip_health_check = true

  # Inject Cilium only (ArgoCD is too large for USERDATA — deployed post-bootstrap
  # via kubectl, matching the documented fallback path). bootstrap_manifests_enabled
  # stays true so the cluster gets its CNI on first boot.
  bootstrap_manifests_enabled = true
  cilium_manifest             = local.cilium_manifest
  argocd_manifest             = ""
  root_app_manifest           = ""
}

# ==============================================================================
# Docker containers — 3 CP, config injected via USERDATA
# ==============================================================================

module "local" {
  source = "../opentofu/modules/providers/local"

  cluster_name        = "${var.cluster_name}-${var.environment}"
  talos_version       = var.talos_version
  control_plane_count = local.cp_count
  worker_count        = 0

  network_cidr        = "${local.net_prefix}.0/24"
  cp_ip_base          = 10
  talos_api_port_base = 50000
  k8s_api_port        = 6443

  # Generated configs from modules/talos (one per CP — identical, node-agnostic)
  control_plane_configs = module.talos.control_plane_machine_configs
}

# ==============================================================================
# Operator config files
# talosconfig endpoints already point at 127.0.0.1 (control_plane_endpoints).
# kubeconfig server is the cluster endpoint (10.5.0.10) — rewrite it to the
# host-reachable 127.0.0.1:6443 port mapping.
# ==============================================================================

resource "local_file" "talosconfig" {
  content         = module.talos.talosconfig
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}

resource "local_file" "kubeconfig" {
  count = var.talos_bootstrap ? 1 : 0
  content = replace(
    module.talos.kubeconfig_raw,
    "https://${local.cp_ips[0]}:6443",
    module.local.k8s_api_host_endpoint
  )
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
}
