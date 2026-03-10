provider "talos" {}
provider "scaleway" {}
provider "openstack" {
  # Fournir un dummy auth_url si OVH n'est pas le provider actif
  auth_url = length(compact([local.active_providers[0] == "ovh" ? "ovh" : ""])) > 0 ? null : "http://dummy.local:5000/v3"
}
provider "outscale" {
  # Fournir une dummy region si Outscale n'est pas le provider actif
  region = length(compact([local.active_providers[0] == "outscale" ? "outscale" : ""])) > 0 ? try(local.outscale_dist.region, "eu-west-2") : "dummy-region-1"
  endpoints {
    api = length(compact([local.active_providers[0] == "outscale" ? "outscale" : ""])) > 0 ? null : "https://dummy.outscale.local"
  }
}

# S3-compatible provider for backups (works with Scaleway, Outscale, OVH, MinIO, etc.)
provider "aws" {
  alias  = "backup"
  region = var.backup_s3_region

  endpoints {
    s3 = var.backup_s3_endpoint
  }

  # Required for S3-compatible providers that are not AWS
  skip_credentials_validation = true
  skip_region_validation      = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
}


locals {
  # Determine active providers for validation
  active_providers = compact([
    (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? "scaleway" : "",
    (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? "ovh" : "",
    (local.outscale_dist.control_planes + local.outscale_dist.workers) > 0 ? "outscale" : ""
  ])
}

# Enforce Single Cloud Provider Constraint
resource "terraform_data" "validate_single_provider" {
  input = local.active_providers # Trigger separate lifecycle check on input change
  lifecycle {
    precondition {
      condition     = length(local.active_providers) == 1
      error_message = "Only one cloud provider can be active at a time. Please check your 'node_distribution' variable. Active providers found: ${join(", ", local.active_providers)}"
    }
  }
}

module "talos" {
  source = "./modules/talos"

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://127.0.0.1:6443" # Placeholder — actual endpoint is set in provider module config.tf
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

locals {
  # Default provider configurations
  scw_dist      = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = "talos", zones = null, subnet_id = null }, try(var.node_distribution["scaleway"], {}))
  ovh_dist      = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = null, zones = null, subnet_id = null }, try(var.node_distribution["ovh"], {}))
  outscale_dist = merge({ control_planes = 0, workers = 0, region = null, zone = null, instance_type = null, image_id = null, image_name = null, zones = null, subnet_id = null }, try(var.node_distribution["outscale"], {}))
}

# ==============================================================================
# Scaleway
# ==============================================================================
module "scw" {
  source = "./modules/providers/scw"

  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name

  control_plane_count = local.scw_dist.control_planes
  worker_count        = local.scw_dist.workers

  machine_secrets    = module.talos.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  image_id         = local.scw_dist.image_id
  image_name       = local.scw_dist.image_name
  zone             = local.scw_dist.zone
  region           = local.scw_dist.region
  instance_type    = local.scw_dist.instance_type
  additional_zones = local.scw_dist.zones != null ? local.scw_dist.zones : ["fr-par-1", "fr-par-2", "fr-par-3"]

  # Security configuration
  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "scaleway", "")

  # Admin LB toggle
  admin_lb_enabled = var.admin_lb_enabled
}

# ==============================================================================
# OVH
# ==============================================================================
module "ovh" {
  source = "./modules/providers/ovh"

  count = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? 1 : 0

  cluster_name        = var.cluster_name
  control_plane_count = local.ovh_dist.control_planes
  worker_count        = local.ovh_dist.workers
  machine_secrets     = module.talos.machine_secrets
  cluster_endpoint    = "https://127.0.0.1:6443"
  talos_version       = var.talos_version
  kubernetes_version  = var.kubernetes_version
  image_id            = coalesce(local.ovh_dist.image_id, "IMAGE_ID_NEEDED")
  region              = local.ovh_dist.region
  flavor_name         = local.ovh_dist.instance_type
  admin_ip            = var.admin_ip
  bastion_ssh_key     = lookup(var.bastion_ssh_keys, "ovh", "")
}

# ==============================================================================
# Outscale
# ==============================================================================
module "outscale" {
  source = "./modules/providers/outscale"

  count = (local.outscale_dist.control_planes + local.outscale_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name

  control_plane_count = local.outscale_dist.control_planes
  worker_count        = local.outscale_dist.workers

  machine_secrets    = module.talos.machine_secrets
  cluster_endpoint   = "https://127.0.0.1:6443"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  image_id      = coalesce(local.outscale_dist.image_id, "ami-ce7e9d99")
  region        = local.outscale_dist.region
  subnet_id     = local.outscale_dist.subnet_id
  instance_type = local.outscale_dist.instance_type

  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "outscale", "")
}

# ==============================================================================
# Talos Bootstrap (native provider resources, conditional on admin_lb_enabled)
# ==============================================================================

locals {
  # Pick the first control plane IP from the active provider for bootstrap
  bootstrap_node_ip = coalesce(
    try(module.scw[0].control_plane_private_ips[0], null),
    try(module.ovh[0].control_plane_private_ips[0], null),
    try(module.outscale[0].control_plane_private_ips[0], null),
    "127.0.0.1"
  )

  # Admin LB IP
  admin_lb_ip = coalesce(
    try(module.scw[0].admin_lb_ip, null),
    try(module.ovh[0].admin_lb_ip, null),
    try(module.outscale[0].admin_lb_ip, null),
    "127.0.0.1"
  )
}

# Bootstrap etcd on the first control plane
resource "talos_machine_bootstrap" "this" {
  count = var.admin_lb_enabled ? 1 : 0

  client_configuration = module.talos.client_configuration
  node                 = local.bootstrap_node_ip
  endpoint             = local.admin_lb_ip

  depends_on = [module.scw, module.ovh, module.outscale]
}

# Retrieve kubeconfig from the cluster
resource "talos_cluster_kubeconfig" "this" {
  count = var.admin_lb_enabled ? 1 : 0

  client_configuration = module.talos.client_configuration
  node                 = local.bootstrap_node_ip
  endpoint             = local.admin_lb_ip

  depends_on = [talos_machine_bootstrap.this]
}

# Write kubeconfig to local file
resource "local_file" "kubeconfig" {
  count = var.admin_lb_enabled ? 1 : 0

  content         = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  filename        = "${path.root}/kubeconfig"
  file_permission = "0600"
}

# Write talosconfig to local file
resource "local_file" "talosconfig" {
  count = var.admin_lb_enabled ? 1 : 0

  content         = module.talos.talosconfig
  filename        = "${path.root}/talosconfig"
  file_permission = "0600"
}
