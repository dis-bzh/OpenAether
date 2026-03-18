# ==============================================================================
# Talos Machine Secrets
# ==============================================================================

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ==============================================================================
# Client Configuration (talosctl)
# ==============================================================================

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = var.control_plane_ips
}

# ==============================================================================
# Control Plane Machine Configuration
# Includes inlineManifests for Cilium, ArgoCD, and root app
# ==============================================================================

data "talos_machine_configuration" "control_plane" {
  count              = var.control_plane_count
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        certSANs = concat(
          ["127.0.0.1", "localhost"],
          compact([var.k8s_lb_ip]),
          var.control_plane_ips
        )
        install = {
          disk  = "/dev/vda"
          wipe  = true
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
        kubelet = {
          defaultRuntimeSeccompProfileEnabled = true
        }
        features = {
          diskQuotaSupport = true
          kubePrism = {
            enabled = true
            port    = 7445
          }
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none" # Cilium injected via inlineManifests
          }
        }
        proxy = {
          disabled = true # kube-proxy replaced by Cilium
        }
        # Bootstrap manifests injected into the cluster at first boot
        inlineManifests = [
          {
            name     = "cilium"
            contents = var.cilium_manifest
          },
          {
            name     = "argocd-install"
            contents = var.argocd_manifest
          },
          {
            name     = "argocd-root-app"
            contents = var.root_app_manifest
          },
        ]
      }
    })
  ]
}

# ==============================================================================
# Worker Machine Configuration
# ==============================================================================

data "talos_machine_configuration" "worker" {
  count              = var.worker_count
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          wipe  = true
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
        features = {
          diskQuotaSupport = true
          kubePrism = {
            enabled = true
            port    = 7445
          }
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    })
  ]
}

# ==============================================================================
# Apply Machine Configurations
# The Talos provider connects to nodes on port 50000/TCP via their private IPs.
# The operator must ensure network reachability (bastion tunnel or VPC access).
# ==============================================================================

resource "talos_machine_configuration_apply" "control_plane" {
  count = var.control_plane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane[count.index].machine_configuration
  endpoint                    = var.control_plane_ips[count.index]
  node                        = var.control_plane_ips[count.index]
}

resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  endpoint                    = var.worker_ips[count.index]
  node                        = var.worker_ips[count.index]
}

# ==============================================================================
# Bootstrap
# Triggers the initial etcd/control plane bootstrap on the first CP node.
# This is a one-shot operation — idempotent on subsequent applies.
# ==============================================================================

resource "talos_machine_bootstrap" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = var.control_plane_ips[0]
  node                 = var.control_plane_ips[0]

  depends_on = [
    talos_machine_configuration_apply.control_plane
  ]
}

# ==============================================================================
# Kubeconfig
# Retrieved after bootstrap. Uses the first CP node as endpoint.
# ==============================================================================

resource "talos_cluster_kubeconfig" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane_ips[0]
  endpoint             = var.control_plane_ips[0]

  depends_on = [talos_machine_bootstrap.this]
}
