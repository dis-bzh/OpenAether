terraform {
  required_providers {
    outscale = {
      source  = "outscale/outscale"
      version = ">= 0.12.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7.0"
    }
  }
}
