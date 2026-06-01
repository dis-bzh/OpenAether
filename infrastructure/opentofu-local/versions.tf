terraform {
  required_version = ">= 1.11.0"

  # Local state — no remote backend for Docker testing
  # State is stored in terraform.tfstate (gitignored)

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}
