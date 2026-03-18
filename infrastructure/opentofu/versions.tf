terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.68.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}
