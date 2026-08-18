terraform {
  required_version = ">= 1.11.0"

  # No backend: this root creates nothing outside a local emulator, so its state
  # is disposable by construction (same reasoning as opentofu-local).
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      # PINNED BEHIND THE REAL LANES, and that is a known, deliberate divergence.
      #
      # Scaleway moved private NICs from `instance/v1 · private_nics` to
      # `instance/v2alpha1 · private-network-interfaces`, and provider v2.81.0
      # (released 2026-08-17) follows. The emulator does not: feint v0.8.0 — the
      # newest published — serves 130 instance routes, all under /instance/v1, and
      # answers 501 for the new one. Measured 2026-08-18; ~> 2.80.0 applies the
      # emulated lane cleanly, 8 added and 8 destroyed.
      #
      # THE COST: this lane no longer emulates the provider the clusters actually
      # run. It still catches what it exists for — our own module shapes — but it
      # can no longer catch a break introduced by a provider release, which is
      # exactly what happened here. docs/backlog.md carries the entry.
      #
      # REMOVE THIS when feint serves the v2alpha1 route: restore `~> 2.68` and
      # bump FEINT_VERSION in scripts/dev/feint.sh in the same commit.
      version = "~> 2.80.0"
    }
    outscale = {
      source  = "outscale/outscale"
      version = ">= 1.7.0"
    }
  }
}
