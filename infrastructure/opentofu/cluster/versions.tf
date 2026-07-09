terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Latest stable line. The 0.12.x series only has pre-releases (0.12.0-alpha.*),
      # so "~> 0.12.0" resolved to nothing; 0.11.0 is the newest published stable.
      version = "~> 0.11.0"
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
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
