terraform {
  required_version = ">= 1.11.0"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Bounded ceiling so a consumer with a loose root can't drift onto the
      # 0.12.x pre-release line. Lower bound stays wide enough to satisfy both
      # the cluster root (~> 0.11.0) and the local stack (pinned 0.10.1).
      version = ">= 0.7.0, < 0.12.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
