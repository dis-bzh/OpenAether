terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # Aligned with the cluster root (~> 2.68) so the module can't silently
      # resolve an older 2.4x line when consumed standalone.
      version = "~> 2.68"
    }
  }
}
