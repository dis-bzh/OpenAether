terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.69.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "2.11.0"
    }
    outscale = {
      source  = "outscale/outscale"
      version = "1.3.2"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
