# ==============================================================================
# Providers
# ==============================================================================

provider "talos" {}
provider "scaleway" {}
provider "openstack" {}
provider "outscale" {}

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
# Provider Distribution Locals
# Extract per-provider node counts with safe defaults.
# ==============================================================================

locals {
  scw_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = null
    zone               = null
    instance_type      = null
    image_id           = null
    image_name         = "talos"
    zones              = null
    availability_zones = null
  }, try(var.node_distribution["scaleway"], {}))

  ovh_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = "GRA11"
    flavor_name        = "b2-7"
    image_id           = null
    image_name         = "talos"
    network_name       = "Ext-Net"
    availability_zones = ["nova"]
    bastion_image_id   = "Ubuntu 22.04"
  }, try(var.node_distribution["ovh"], {}))

  osc_dist = merge({
    control_planes     = 0
    workers            = 0
    region             = "eu-west-2"
    instance_type      = "tinav5.c2r4p1"
    image_id           = null
    image_name         = "talos"
    availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    bastion_image_id   = null
  }, try(var.node_distribution["outscale"], {}))
}

# ==============================================================================
# Validation — Only one provider can be active per cluster apply
# Note: local Docker testing lives in ../opentofu-local (not a cloud provider).
# ==============================================================================

locals {
  active_providers = compact([
    (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? "scaleway" : null,
    (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? "ovh" : null,
    (local.osc_dist.control_planes + local.osc_dist.workers) > 0 ? "outscale" : null,
  ])
}

check "single_provider_per_cluster" {
  assert {
    condition     = length(local.active_providers) <= 1
    error_message = "Only one provider can be active per cluster apply. Use separate env files (envs/workload-ovh.tfvars) for each cluster."
  }
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
# OVH / OpenStack Infrastructure
# ==============================================================================

module "ovh" {
  source = "./modules/providers/ovh"

  count = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.ovh_dist.control_planes
  worker_count        = local.ovh_dist.workers

  region             = local.ovh_dist.region
  flavor_name        = local.ovh_dist.flavor_name
  image_id           = local.ovh_dist.image_id
  network_name       = local.ovh_dist.network_name
  availability_zones = local.ovh_dist.availability_zones
  bastion_image_id   = local.ovh_dist.bastion_image_id

  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "ovh", "")
}

# ==============================================================================
# Outscale Infrastructure
# ==============================================================================

module "outscale" {
  source = "./modules/providers/outscale"

  count = (local.osc_dist.control_planes + local.osc_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.osc_dist.control_planes
  worker_count        = local.osc_dist.workers

  region             = local.osc_dist.region
  instance_type      = local.osc_dist.instance_type
  image_id           = local.osc_dist.image_id
  availability_zones = local.osc_dist.availability_zones
  bastion_image_id   = local.osc_dist.bastion_image_id

  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "outscale", "")
}

# ==============================================================================
# Provider-Agnostic Junction Point
#
# CONTRACT between the cloud provider layer and the Talos layer.
# coalesce() selects the first non-null value across all providers.
# Since only one provider is active per apply, exactly one will have a value.
#
# See: modules/providers/provider-contract.md
# ==============================================================================

locals {
  k8s_lb_ip = coalesce(
    try(module.scw[0].k8s_lb_ip, null),
    try(module.ovh[0].k8s_lb_ip, null),
    try(module.outscale[0].k8s_lb_ip, null),
    "127.0.0.1"
  )

  control_plane_ips = coalesce(
    length(try(module.scw[0].control_plane_private_ips, [])) > 0 ? module.scw[0].control_plane_private_ips : null,
    length(try(module.ovh[0].control_plane_private_ips, [])) > 0 ? module.ovh[0].control_plane_private_ips : null,
    length(try(module.outscale[0].control_plane_private_ips, [])) > 0 ? module.outscale[0].control_plane_private_ips : null,
    []
  )

  worker_ips = coalesce(
    length(try(module.scw[0].worker_private_ips, [])) > 0 ? module.scw[0].worker_private_ips : null,
    length(try(module.ovh[0].worker_private_ips, [])) > 0 ? module.ovh[0].worker_private_ips : null,
    length(try(module.outscale[0].worker_private_ips, [])) > 0 ? module.outscale[0].worker_private_ips : null,
    []
  )

  active_provider = length(local.active_providers) > 0 ? local.active_providers[0] : "none"
}

# ==============================================================================
# Bootstrap Manifests — Loaded from static files
# Generate with: ./scripts/render-bootstrap-manifests.sh
# ==============================================================================

locals {
  cilium_manifest = var.cilium_manifest != null ? var.cilium_manifest : file("${path.module}/bootstrap-manifests/cilium.yaml")
  argocd_manifest = var.argocd_manifest != null ? var.argocd_manifest : file("${path.module}/bootstrap-manifests/argocd-install.yaml")
  root_app_manifest = var.root_app_manifest != null ? var.root_app_manifest : templatefile("${path.module}/bootstrap-manifests/argocd-root-app.yaml.tftpl", {
    namespace    = var.argocd_namespace
    git_repo_url = var.git_repo_url
    environment  = var.environment
    cluster_role = var.cluster_role
  })
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
  control_plane_count = var.talos_bootstrap ? length(local.control_plane_ips) : 0
  worker_count        = var.talos_bootstrap ? length(local.worker_ips) : 0

  k8s_lb_ip         = local.k8s_lb_ip
  control_plane_ips = local.control_plane_ips
  worker_ips        = local.worker_ips

  # Bootstrap manifests — Cilium is always injected (CNI required),
  # ArgoCD only on initial bootstrap (not on upgrades/DRP)
  bootstrap_manifests_enabled = var.talos_bootstrap
  cilium_manifest             = local.cilium_manifest
  argocd_manifest             = local.argocd_manifest
  root_app_manifest           = local.root_app_manifest

  depends_on = [module.scw, module.ovh, module.outscale]
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
