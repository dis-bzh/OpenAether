terraform {
  required_version = ">= 1.11.0"

  required_providers {
    outscale = {
      source = "outscale/outscale"
      # Aligned with the cluster root: 1.x for the api{} block.
      version = ">= 1.7.0"
    }
  }
}
