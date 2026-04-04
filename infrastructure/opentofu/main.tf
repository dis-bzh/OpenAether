# ==============================================================================
# Providers
# ==============================================================================

provider "talos" {}
provider "scaleway" {}

# S3-compatible provider for backups (Scaleway Object Storage)
provider "aws" {
  alias  = "backup"
  region = var.backup_s3_region

  endpoints {
    s3 = var.backup_s3_endpoint
  }

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
}

# ==============================================================================
# Provider Validation
# Currently Scaleway-first. Multi-provider support can be re-introduced
# by adding provider modules and adjusting this validation.
# ==============================================================================

locals {
  scw_dist = merge({
    control_planes = 0
    workers        = 0
    region         = null
    zone           = null
    instance_type  = null
    image_id       = null
    image_name     = "talos"
    zones          = null
  }, try(var.node_distribution["scaleway"], {}))
}

# ==============================================================================
# Scaleway Infrastructure
# ==============================================================================

module "scw" {
  source = "./modules/providers/scw"

  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.scw_dist.control_planes
  worker_count        = local.scw_dist.workers

  image_id         = local.scw_dist.image_id
  image_name       = local.scw_dist.image_name
  zone             = local.scw_dist.zone
  region           = local.scw_dist.region
  instance_type    = local.scw_dist.instance_type
  additional_zones = local.scw_dist.zones != null ? local.scw_dist.zones : ["fr-par-1", "fr-par-2", "fr-par-3"]

  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "scaleway", "")
}

# ==============================================================================
# Aggregate IPs from provider module
# ==============================================================================

locals {
  k8s_lb_ip = try(module.scw[0].k8s_lb_ip, "127.0.0.1")

  control_plane_ips = try(module.scw[0].control_plane_private_ips, [])

  worker_ips = try(module.scw[0].worker_private_ips, [])
}

# ==============================================================================
# Bootstrap Manifests — Loaded from static files
# Generate with: ./scripts/render-bootstrap-manifests.sh
# ==============================================================================

locals {
  cilium_manifest = file("${path.module}/bootstrap-manifests/cilium.yaml")
  argocd_manifest = file("${path.module}/bootstrap-manifests/argocd-install.yaml")
  root_app_manifest = templatefile("${path.module}/bootstrap-manifests/argocd-root-app.yaml.tftpl", {
    namespace    = var.argocd_namespace
    git_repo_url = var.git_repo_url
    environment  = var.environment
  })
}

# ==============================================================================
# Validation
# ==============================================================================
check "manifests_rendered" {
  assert {
    condition     = !strcontains(local.cilium_manifest, "Placeholder")
    error_message = "Cilium manifest is a placeholder. Please run ./scripts/render-bootstrap-manifests.sh first."
  }
}

# ==============================================================================
# Talos Cluster (secrets, config, bootstrap, kubeconfig)
# ==============================================================================

module "talos" {
  source = "./modules/talos"

  cluster_name       = "${var.cluster_name}-${var.environment}"
  cluster_endpoint   = "https://${local.k8s_lb_ip}:6443"
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  # Phase 2 apply sets talos_bootstrap = true
  control_plane_count = var.talos_bootstrap ? local.scw_dist.control_planes : 0
  worker_count        = var.talos_bootstrap ? local.scw_dist.workers : 0

  k8s_lb_ip         = local.k8s_lb_ip
  control_plane_ips = local.control_plane_ips
  worker_ips        = local.worker_ips

  # Bootstrap manifests injected via Talos inlineManifests
  cilium_manifest   = local.cilium_manifest
  argocd_manifest   = local.argocd_manifest
  root_app_manifest = local.root_app_manifest

  depends_on = [module.scw]
}

# ==============================================================================
# Local config files (for operator convenience)
# ==============================================================================

resource "local_file" "talosconfig" {
  content         = module.talos.talosconfig
  filename        = "${path.root}/talosconfig"
  file_permission = "0600"
}

resource "local_file" "kubeconfig" {
  count           = length(local.control_plane_ips) > 0 ? 1 : 0
  content         = module.talos.kubeconfig_raw
  filename        = "${path.root}/kubeconfig"
  file_permission = "0600"
}
