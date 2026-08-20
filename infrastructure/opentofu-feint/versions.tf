terraform {
  required_version = ">= 1.11.0"

  # No backend: this root creates nothing outside a local emulator, so its state
  # is disposable by construction (same reasoning as opentofu-local).
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # Same constraint as the real lanes on purpose: a divergence here means the
      # emulated lane stops testing the provider the clusters actually run.
      version = "~> 2.68"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 1.7.0"
    }
  }
}
