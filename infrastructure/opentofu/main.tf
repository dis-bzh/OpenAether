provider "talos" {}
provider "scaleway" {}
provider "openstack" {}
provider "outscale" {
  region = try(local.outscale_dist.region, "eu-west-2")
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
  # Use localhost for Talos configuration to allow bootstrapping via SSH tunnel
  # This breaks the circular dependency between LB creation (Module) and Node Config (Talos Module)
  formatted_endpoint = "https://127.0.0.1:6443"

  # Public endpoint (Load Balancer) for Outputs
  effective_endpoint = coalesce(
    try(module.scw[0].lb_ip, ""),
    try(module.ovh[0].lb_ip, ""),
    try(module.outscale[0].lb_ip, ""),
    var.cluster_endpoint
  )

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

  image_id         = local.scw_dist.image_id
  image_name       = local.scw_dist.image_name
  zone             = local.scw_dist.zone
  region           = local.scw_dist.region
  instance_type    = local.scw_dist.instance_type
  additional_zones = local.scw_dist.zones != null ? local.scw_dist.zones : ["fr-par-1", "fr-par-2", "fr-par-3"]

  # Security configuration
  admin_ip        = var.admin_ip
  bastion_ssh_key = lookup(var.bastion_ssh_keys, "scaleway", "")
  
  # Inject Cilium manifest for self-bootstrap
  extra_manifests = [data.helm_template.cilium.manifest]
}

# ------------------------------------------------------------------------------
# OVH
# ------------------------------------------------------------------------------
module "ovh" {
  source = "./modules/providers/ovh"

  count = (local.ovh_dist.control_planes + local.ovh_dist.workers) > 0 ? 1 : 0

  cluster_name = var.cluster_name
  # ... (leaving other modules as is for now, they might need updates later)
  control_plane_count = local.ovh_dist.control_planes
  worker_count        = local.ovh_dist.workers
  machine_secrets    = module.talos.machine_secrets
  cluster_endpoint   = local.formatted_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  image_id    = coalesce(local.ovh_dist.image_id, "IMAGE_ID_NEEDED")
  region      = local.ovh_dist.region
  flavor_name = local.ovh_dist.instance_type
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

  image_id  = coalesce(local.outscale_dist.image_id, "ami-ce7e9d99")
  region    = local.outscale_dist.region
  subnet_id = local.outscale_dist.subnet_id
  
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
  endpoint             = local.effective_endpoint
  client_configuration = module.talos.client_configuration
  
  depends_on = [
    module.scw,
    module.ovh,
    module.outscale
  ]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration
  node                 = local.bootstrap_node
  endpoint             = local.effective_endpoint
  
  # Wait for bootstrap to complete
  depends_on = [talos_machine_bootstrap.this]
}

# Export configs to local files for use by kubectl and helm
resource "null_resource" "export_configs" {
  triggers = {
    kubeconfig_hash = sha1(talos_cluster_kubeconfig.this.kubeconfig_raw)
    talosconfig_hash = sha1(module.talos.talosconfig)
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "${talos_cluster_kubeconfig.this.kubeconfig_raw}" > ${path.root}/kubeconfig
      echo "${module.talos.talosconfig}" > ${path.root}/talosconfig
      chmod 600 ${path.root}/kubeconfig ${path.root}/talosconfig
      echo "✅ Kubeconfig and Talosconfig exported"
    EOT
  }

  depends_on = [
    talos_cluster_kubeconfig.this
  ]
}




