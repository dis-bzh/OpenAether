provider "talos" {}
provider "scaleway" {}
provider "openstack" {}
provider "outscale" {}


# Calculate endpoint: prioritize LB IPs, otherwise fallback to var.cluster_endpoint
locals {
  # We need to know which provider is active to pick the right LB
  # For now, simplistic logic: pick first non-empty LB IP from active modules
  # Note: `one(...)` or similar logic might be needed if multiple modules are active (multi-cloud)

  effective_endpoint = coalesce(
    try(module.scw[0].lb_ip, ""),
    try(module.ovh[0].lb_ip, ""),
    try(module.outscale[0].lb_ip, ""),
    var.cluster_endpoint
  )

  # Format endpoint as URL if not already
  formatted_endpoint = can(regex("^https://", local.effective_endpoint)) ? local.effective_endpoint : "https://${local.effective_endpoint}:6443"
}

module "talos" {
  source = "./modules/talos"

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.formatted_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

locals {
  # Default provider configurations
  # You can override specific settings in var.node_distribution if needed

  # Parse distribution
  scw_dist      = lookup(var.node_distribution, "scaleway", { control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null })
  ovh_dist      = lookup(var.node_distribution, "ovh", { control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null })
  outscale_dist = lookup(var.node_distribution, "outscale", { control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null })
}

# ------------------------------------------------------------------------------
# Scaleway
# ------------------------------------------------------------------------------
module "scw" {
  source = "./modules/providers/scw"

  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name

  control_plane_count = local.scw_dist.control_planes
  worker_count        = local.scw_dist.workers

  control_plane_config = module.talos.controlplane_machine_config
  worker_config        = module.talos.worker_machine_config

  image_id      = coalesce(local.scw_dist.image_id, "IMAGE_ID_NEEDED")
  zone          = local.scw_dist.zone
  region        = local.scw_dist.region
  instance_type = local.scw_dist.instance_type

  # Security configuration
  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "scaleway", "")
}

# ------------------------------------------------------------------------------
# OVH
# ------------------------------------------------------------------------------
module "ovh" {
  source = "./modules/providers/ovh"

  count = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name

  control_plane_count = local.ovh_dist.control_planes
  worker_count        = local.ovh_dist.workers

  control_plane_config = module.talos.controlplane_machine_config
  worker_config        = module.talos.worker_machine_config

  image_id    = coalesce(local.ovh_dist.image_id, "IMAGE_ID_NEEDED")
  region      = local.ovh_dist.region
  flavor_name = local.ovh_dist.instance_type
}

# ------------------------------------------------------------------------------
# Outscale
# ------------------------------------------------------------------------------
module "outscale" {
  source = "./modules/providers/outscale"

  count = (local.outscale_dist.control_planes + local.outscale_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name

  control_plane_count = local.outscale_dist.control_planes
  worker_count        = local.outscale_dist.workers

  control_plane_config = module.talos.controlplane_machine_config
  worker_config        = module.talos.worker_machine_config

  image_id = coalesce(local.outscale_dist.image_id, "ami-ce7e9d99")
  region   = local.outscale_dist.region
  # Outscale module likely expects 'instance_type' or 'vm_type', checking variables.tf would confirm but instance_type is standard
  instance_type = local.outscale_dist.instance_type
}
