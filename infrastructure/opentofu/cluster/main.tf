# ==============================================================================
# Providers
# ==============================================================================

provider "talos" {}
provider "scaleway" {}

# Only the OVH module uses OpenStack. When OVH is not the active provider we feed
# a placeholder auth_url so a Scaleway/Outscale-only apply doesn't require OVH
# creds; for an OVH deploy auth_url=null falls back to the OS_AUTH_URL env var.
provider "openstack" {
  auth_url = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? null : "https://auth.placeholder.invalid/v3"
}

# Outscale API creds fed explicitly (Taskfile sets TF_VAR_outscale_* from the
# resolved S3/API keys) so auth doesn't depend on the exact OSC_* env var names.
# Empty/null when not deploying Outscale → no effect on Scaleway/OVH applies.
provider "outscale" {
  access_key_id = var.outscale_access_key_id != "" ? var.outscale_access_key_id : null
  secret_key_id = var.outscale_secret_key_id != "" ? var.outscale_secret_key_id : null
  region        = local.active_provider == "outscale" ? local.osc_dist.region : null
}

# Backups go through the AWS CLI (scripts/ops/backup-artifacts.sh + backup-state.sh),
# not a Terraform provider — the artifacts/state are streamed to S3-compatible
# stores with per-call creds/endpoints (primary + cross-provider replica), which
# the aws provider can't express cleanly. So there is intentionally no aws provider.

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
    region             = "EU-WEST-PAR"
    flavor_name        = "b3-8"
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
  source = "../modules/providers/scw"

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

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "scaleway", [])
}

# ==============================================================================
# OVH / OpenStack Infrastructure
# ==============================================================================

module "ovh" {
  source = "../modules/providers/ovh"

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

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "ovh", [])
}

# ==============================================================================
# Outscale Infrastructure
# ==============================================================================

module "outscale" {
  source = "../modules/providers/outscale"

  count = (local.osc_dist.control_planes + local.osc_dist.workers) > 0 ? 1 : 0

  cluster_name        = "${var.cluster_name}-${var.environment}"
  control_plane_count = local.osc_dist.control_planes
  worker_count        = local.osc_dist.workers

  instance_type      = local.osc_dist.instance_type
  image_id           = local.osc_dist.image_id
  availability_zones = local.osc_dist.availability_zones
  bastion_image_id   = local.osc_dist.bastion_image_id

  worker_storage = var.worker_storage

  admin_ip         = var.admin_ip
  bastion_ssh_keys = lookup(var.bastion_ssh_keys, "outscale", [])
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

  bastion_ip = coalesce(
    try(module.scw[0].bastion_ip, null),
    try(module.ovh[0].bastion_ip, null),
    try(module.outscale[0].bastion_ip, null),
    "<bastion-ip>"
  )

  # SSH user for the bastion tunnels, by provider:
  #   scaleway — a dedicated unprivileged "bastion" user via cloud-init (no root login)
  #   ovh      — the OpenStack Ubuntu image's default "ubuntu"
  #   outscale — Outscale's official OMIs default to "outscale" (NOT "ubuntu")
  bastion_user = lookup({
    scaleway = "bastion"
    ovh      = "ubuntu"
    outscale = "outscale"
  }, local.active_provider, "ubuntu")

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

  # Planned node counts from node_distribution — known at PLAN time, unlike the
  # private IPs above (which are unknown until the VMs exist). Use these to gate
  # count/for_each so the plan can be computed.
  total_control_planes = local.scw_dist.control_planes + local.ovh_dist.control_planes + local.osc_dist.control_planes
  total_workers        = local.scw_dist.workers + local.ovh_dist.workers + local.osc_dist.workers
}

# ==============================================================================
# Bootstrap Manifests — Loaded from static files
# Generate with: ./scripts/render-bootstrap-manifests.sh
# ==============================================================================

locals {
  cilium_manifest = var.cilium_manifest != null ? var.cilium_manifest : file("${path.module}/bootstrap-manifests/cilium.yaml")
  flux_manifest   = var.flux_manifest != null ? var.flux_manifest : file("${path.module}/bootstrap-manifests/flux-install.yaml")
  flux_bootstrap_manifest = var.flux_bootstrap_manifest != null ? var.flux_bootstrap_manifest : templatefile("${path.module}/bootstrap-manifests/flux-bootstrap.yaml.tftpl", {
    namespace    = var.flux_namespace
    git_repo_url = var.git_repo_url
    git_branch   = "main"
    cluster_role = var.cluster_role
  })
}

# ==============================================================================
# Talos Cluster (secrets, config, bootstrap, kubeconfig)
# ==============================================================================

module "talos" {
  source = "../modules/talos"

  cluster_name       = "${var.cluster_name}-${var.environment}"
  cluster_endpoint   = "https://${local.k8s_lb_ip}:6443"
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  # Phase 2 apply sets talos_bootstrap = true. Use the planned counts (known at
  # plan) rather than length(local.*_ips) (unknown until the VMs exist), so the
  # talos module's per-node count/for_each can be computed in Phase 2.
  control_plane_count = var.talos_bootstrap ? local.total_control_planes : 0
  worker_count        = var.talos_bootstrap ? local.total_workers : 0

  k8s_lb_ip         = local.k8s_lb_ip
  control_plane_ips = local.control_plane_ips
  worker_ips        = local.worker_ips

  # Phase 2 reaches the private nodes through per-node SSH tunnels on localhost
  # (see the `instructions` output). `endpoint` is where the provider connects;
  # node identity stays the private IP. CPs: 127.0.0.1:5000+i, workers: :5010+i.
  control_plane_endpoints = var.talos_bootstrap ? [for i in range(local.total_control_planes) : "127.0.0.1:${50000 + i}"] : []
  worker_endpoints        = var.talos_bootstrap ? [for i in range(local.total_workers) : "127.0.0.1:${50100 + i}"] : []

  # Bootstrap manifests — Cilium is always injected (CNI required),
  # Flux only on initial bootstrap (not on upgrades/DRP)
  bootstrap_manifests_enabled = var.talos_bootstrap
  cilium_manifest             = local.cilium_manifest
  flux_manifest               = local.flux_manifest
  flux_bootstrap_manifest     = local.flux_bootstrap_manifest

  # Dedicated worker data volumes (encrypted UserVolumeConfig). Empty on local.
  worker_storage = var.worker_storage

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
  count           = local.total_control_planes > 0 ? 1 : 0
  content         = module.talos.kubeconfig_raw
  filename        = "${path.root}/kubeconfig"
  file_permission = "0600"
}
