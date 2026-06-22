terraform {
  required_version = ">= 1.11.0"

  required_providers {
    outscale = {
      source  = "outscale/outscale"
      version = ">= 0.12.0"
    }
  }
}
