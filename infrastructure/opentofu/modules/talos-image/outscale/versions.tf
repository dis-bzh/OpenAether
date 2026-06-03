terraform {
  required_providers {
    outscale = {
      source  = "outscale/outscale"
      version = ">= 0.12.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3.0"
    }
  }
}
