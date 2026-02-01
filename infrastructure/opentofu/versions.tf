terraform {
  required_version = ">= 1.6.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7.0"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.40"
    }
    ovh = {
      source  = "ovh/ovh"
      version = ">= 0.40"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 0.12.0"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.53.0"
    }
  }
}
