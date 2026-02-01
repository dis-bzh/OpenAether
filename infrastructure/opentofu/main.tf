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
  scw_dist      = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = "talos", zones = null, subnet_id = null }, try(var.node_distribution["scaleway"], {}))
  ovh_dist      = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = null, zones = null, subnet_id = null }, try(var.node_distribution["ovh"], {}))
  outscale_dist = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = null, zones = null, subnet_id = null }, try(var.node_distribution["outscale"], {}))
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

  machine_secrets    = module.talos.machine_secrets
  cluster_endpoint   = local.formatted_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  image_id      = local.scw_dist.image_id
  image_name    = local.scw_dist.image_name
  zone          = local.scw_dist.zone
  region        = local.scw_dist.region
  instance_type    = local.scw_dist.instance_type
  additional_zones = local.scw_dist.zones != null ? local.scw_dist.zones : ["fr-par-1", "fr-par-2", "fr-par-3"]

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

  machine_secrets    = module.talos.machine_secrets
  cluster_endpoint   = local.formatted_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  image_id    = coalesce(local.ovh_dist.image_id, "IMAGE_ID_NEEDED")
  region      = local.ovh_dist.region
  flavor_name = local.ovh_dist.instance_type

  # Security configuration
  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "ovh", "")
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

  machine_secrets    = module.talos.machine_secrets
  cluster_endpoint   = local.formatted_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  image_id = coalesce(local.outscale_dist.image_id, "ami-ce7e9d99")
  region   = local.outscale_dist.region
  subnet_id = local.outscale_dist.subnet_id
  # Outscale module likely expects 'instance_type' or 'vm_type', checking variables.tf would confirm but instance_type is standard
  instance_type = local.outscale_dist.instance_type

  # Security configuration
  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "outscale", "")
}

# ------------------------------------------------------------------------------
# Talos Bootstrap & Config Export
# ------------------------------------------------------------------------------

locals {
  # Pick the first control plane IP from the active provider for bootstrap
  bootstrap_node = coalesce(
    try(module.scw[0].control_plane_private_ips[0], null),
    try(module.ovh[0].control_plane_private_ips[0], null),
    try(module.outscale[0].control_plane_private_ips[0], null),
    "127.0.0.1" # Fallback
  )
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.bootstrap_node
  endpoint             = "127.0.0.1"
  client_configuration = module.talos.client_configuration
  
  # Ensure instances are ready before bootstrapping
  depends_on = [
    module.scw,
    module.ovh,
    module.outscale
  ]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration
  node                 = local.bootstrap_node
  endpoint             = "127.0.0.1"
  
  # Wait for bootstrap to complete
  depends_on = [talos_machine_bootstrap.this]
}


