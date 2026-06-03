provider "scaleway" {}

# OpenStack (OVH). Placeholder auth_url unless we're building the OVH image, so a
# scaleway/outscale build doesn't require OS_* creds (auth_url=null falls back to
# the OS_AUTH_URL env var).
provider "openstack" {
  auth_url = var.target_provider == "ovh" ? null : "https://auth.placeholder.invalid/v3"
}

# Outscale API creds fed explicitly (same AK/SK as OOS) so it doesn't depend on
# the exact OSC_* env var names; null when not building Outscale → uses env.
provider "outscale" {
  access_key_id = var.outscale_access_key_id != "" ? var.outscale_access_key_id : null
  secret_key_id = var.outscale_secret_key_id != "" ? var.outscale_secret_key_id : null
  region        = var.target_provider == "outscale" ? var.region : null
}

# ==============================================================================
# Resolve the Image Factory schematic ID from schematic.yaml.
# POST is idempotent: Factory returns the existing ID for identical content.
# ==============================================================================
data "http" "schematic" {
  url    = "https://factory.talos.dev/schematics"
  method = "POST"

  request_headers = {
    "Content-Type" = "application/yaml"
  }

  request_body = file("${path.module}/schematic.yaml")
}

locals {
  schematic_id = jsondecode(data.http.schematic.response_body).id

  # Must match the cluster envs/*.tfvars convention: talos-<platform>-<arch>-<version>
  image_name = "talos-${var.target_provider}-${var.arch}-${var.talos_version}"
  cache_dir  = abspath("${path.root}/.talos-image-cache")
}

# ==============================================================================
# Provider junction — only the selected provider's image module is active.
# ==============================================================================
module "scaleway" {
  source = "../modules/talos-image/scaleway"
  count  = var.target_provider == "scaleway" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  bucket_name   = var.staging_bucket
  region        = var.region
  zones         = var.zones
  s3_endpoint   = var.s3_endpoint
  cache_dir     = local.cache_dir
}

# OVH: OpenStack Glance image, uploaded from the converted Factory artifact (no
# Object Storage staging needed — glance takes the local file directly).
module "ovh" {
  source = "../modules/talos-image/ovh"
  count  = var.target_provider == "ovh" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  cache_dir     = local.cache_dir
}

# Outscale: OOS upload -> snapshot import -> OMI.
module "outscale" {
  source = "../modules/talos-image/outscale"
  count  = var.target_provider == "outscale" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  bucket_name   = var.staging_bucket
  region        = var.region
  s3_endpoint   = var.s3_endpoint
  cache_dir     = local.cache_dir
}
