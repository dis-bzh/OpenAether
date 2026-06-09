terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0-alpha.2"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.68"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.53.0"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 0.12.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}
