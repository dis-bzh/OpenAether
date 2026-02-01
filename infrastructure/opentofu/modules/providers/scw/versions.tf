terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.40"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7.0"
    }
  }
}
