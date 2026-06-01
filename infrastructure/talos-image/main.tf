provider "scaleway" {}

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
}

# ==============================================================================
# Provider junction — only the selected provider's image module is active.
# scaleway implemented; ovh (openstack web_download) + outscale to follow.
# ==============================================================================
module "scaleway" {
  source = "../opentofu/modules/talos-image/scaleway"
  count  = var.target_provider == "scaleway" ? 1 : 0

  talos_version = var.talos_version
  arch          = var.arch
  schematic_id  = local.schematic_id
  image_name    = local.image_name
  bucket_name   = var.image_bucket
  region        = var.scaleway_region
  zones         = var.scaleway_zones
  s3_endpoint   = var.s3_endpoint
  cache_dir     = abspath("${path.root}/.talos-image-cache")
}
