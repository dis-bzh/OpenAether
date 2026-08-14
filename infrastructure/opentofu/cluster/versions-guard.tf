# ==============================================================================
# Talos ↔ Kubernetes version pair
#
# Talos supports the current Kubernetes minor and the five before it (n-5), so a
# pair can be individually valid and jointly unsupported — and nothing checked
# it. Only ranges read from the upstream matrix are encoded here; an unknown
# Talos minor fails on purpose rather than passing silently, so bumping one
# forces a look at:
#   https://docs.siderolabs.com/talos/v1.13/getting-started/support-matrix
# ==============================================================================

locals {
  k8s_minors_by_talos_minor = {
    "1.12" = { min = 30, max = 35 }
    "1.13" = { min = 31, max = 36 }
  }

  talos_minor_key = join(".", slice(split(".", trimprefix(var.talos_version, "v")), 0, 2))
  k8s_minor_num   = tonumber(split(".", trimprefix(var.kubernetes_version, "v"))[1])
  k8s_supported   = lookup(local.k8s_minors_by_talos_minor, local.talos_minor_key, null)
}

resource "terraform_data" "version_pair_guard" {
  input = "${var.talos_version}/${var.kubernetes_version}"

  lifecycle {
    precondition {
      # Conditional, not `&&`: the range is null for an unknown Talos minor, and
      # reading .min off null would error before the message could be shown.
      condition = local.k8s_supported == null ? false : (
        local.k8s_minor_num >= local.k8s_supported.min &&
        local.k8s_minor_num <= local.k8s_supported.max
      )
      error_message = "talos_version ${var.talos_version} and kubernetes_version ${var.kubernetes_version} are not a supported pair. Talos ${local.talos_minor_key} either supports a different Kubernetes range, or is not in cluster/versions-guard.tf yet — check https://docs.siderolabs.com/talos/v1.13/getting-started/support-matrix and extend the map rather than widening it blindly."
    }
  }
}
