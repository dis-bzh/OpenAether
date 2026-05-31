# ==============================================================================
# Talos Machine Secrets
# ==============================================================================

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version

  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# Client Configuration (talosctl)
# ==============================================================================

# ==============================================================================
# Endpoint resolution + delivery mode
# control_plane_endpoints lets local Docker reach nodes via port mappings while
# keeping control_plane_ips as the node identity (etcd/certSANs). Cloud leaves
# the endpoints empty, so they default to the node IPs (unchanged behavior).
# ==============================================================================

locals {
  cp_endpoints     = length(var.control_plane_endpoints) > 0 ? var.control_plane_endpoints : var.control_plane_ips
  worker_endpoints = length(var.worker_endpoints) > 0 ? var.worker_endpoints : var.worker_ips

  # Maintenance-mode apply only for cloud; Docker uses USERDATA injection.
  do_apply = var.config_delivery == "apply"

  # Container platforms need host DNS forwarding (Talos Docker platform docs).
  container_features = var.container_mode ? {
    hostDNS = {
      enabled              = true
      forwardKubeDNSToHost = true
    }
  } : {}
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_endpoints
}

# ==============================================================================
# Inline Manifests — conditional injection
# Cilium is always injected (CNI is required for networking).
# ArgoCD manifests are only injected during initial bootstrap.
# ==============================================================================

locals {
  # Cilium CNI is always required — without it, nodes cannot communicate
  base_manifests = [
    {
      name     = "cilium"
      contents = var.cilium_manifest
    },
  ]

  # ArgoCD is only needed during initial bootstrap. On upgrades/DRP,
  # ArgoCD is already running and manages itself via GitOps.
  argocd_manifests = var.bootstrap_manifests_enabled && var.argocd_manifest != "" ? [
    {
      name     = "argocd-install"
      contents = var.argocd_manifest
    },
    {
      name     = "argocd-root-app"
      contents = var.root_app_manifest
    },
  ] : []

  inline_manifests = concat(local.base_manifests, local.argocd_manifests)
}

# ==============================================================================
# Control Plane Machine Configuration
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
      machine = merge(
        {
          certSANs = concat(
            ["127.0.0.1", "localhost"],
            compact([var.k8s_lb_ip]),
            var.control_plane_ips
          )
          kubelet = {
            defaultRuntimeSeccompProfileEnabled = true
          }
          features = merge({
            diskQuotaSupport = true
            kubePrism = {
              enabled = true
              port    = 7445
            }
          }, local.container_features)
        },
        # In container mode (Docker local testing), skip disk install.
        # Talos detects the container platform and runs without a block device.
        var.container_mode ? {} : {
          install = {
            disk  = "/dev/vda"
            wipe  = true
            image = "ghcr.io/siderolabs/installer:${var.talos_version}"
          }
        }
      )
      cluster = {
        network = {
          cni = {
            name = "none" # Cilium injected via inlineManifests
          }
        }
        proxy = {
          disabled = true # kube-proxy replaced by Cilium
        }
        inlineManifests = local.inline_manifests
      }
    })
  ]

  lifecycle {
    precondition {
      condition     = var.control_plane_count == 0 || !strcontains(var.cilium_manifest, "Placeholder")
      error_message = "Cilium manifest is a placeholder. Run ./scripts/render-bootstrap-manifests.sh before bootstrapping."
    }
  }
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
      machine = merge(
        {
          features = merge({
            diskQuotaSupport = true
            kubePrism = {
              enabled = true
              port    = 7445
            }
          }, local.container_features)
        },
        var.container_mode ? {} : {
          install = {
            disk  = "/dev/vda"
            wipe  = true
            image = "ghcr.io/siderolabs/installer:${var.talos_version}"
          }
        }
      )
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
# Apply Machine Configurations (config_delivery = "apply" only)
# The Talos provider connects to each node's endpoint on 50000/TCP. For cloud,
# endpoints = node IPs (reachable via VPC/tunnel). For Docker (config_delivery =
# "userdata") these resources are skipped — config is injected at container
# creation instead (maintenance-mode apply reboot-loops in containers).
# ==============================================================================

resource "talos_machine_configuration_apply" "control_plane" {
  count = local.do_apply ? var.control_plane_count : 0

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane[count.index].machine_configuration
  endpoint                    = local.cp_endpoints[count.index]
  node                        = var.control_plane_ips[count.index]
}

resource "talos_machine_configuration_apply" "worker" {
  count = local.do_apply ? var.worker_count : 0

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  endpoint                    = local.worker_endpoints[count.index]
  node                        = var.worker_ips[count.index]
}

# ==============================================================================
# Bootstrap
# Triggers the initial etcd/control plane bootstrap on the first CP node.
# One-shot, idempotent. In 'userdata' mode there are no apply resources to wait
# on — the provider retries connection until the (USERDATA-configured) node is up.
# ==============================================================================

resource "talos_machine_bootstrap" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.cp_endpoints[0]
  node                 = var.control_plane_ips[0]

  depends_on = [
    talos_machine_configuration_apply.control_plane
  ]
}

# ==============================================================================
# Health Check
# Waits for the cluster to be healthy after bootstrap.
# Validates etcd, kubelet, apid, and all nodes reporting ready.
# control_plane_nodes uses node identity IPs; endpoints use the reachable addrs.
# ==============================================================================

data "talos_cluster_health" "this" {
  count = var.control_plane_count > 0 && !var.skip_health_check ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = var.control_plane_ips
  worker_nodes         = var.worker_ips
  # A single reachable endpoint is sufficient — apid checks the whole cluster
  # through it (this is how `talosctl health` works). Using all endpoints can
  # stall when some aren't directly reachable (e.g. local Docker port mappings).
  endpoints              = [local.cp_endpoints[0]]
  skip_kubernetes_checks = var.skip_kubernetes_health_checks

  # Allow ample time: a multi-CP cluster pulling Cilium/CoreDNS images on first
  # boot can take several minutes to report fully healthy.
  timeouts = {
    read = var.health_check_timeout
  }

  depends_on = [talos_machine_bootstrap.this]
}

# ==============================================================================
# Kubeconfig
# Retrieved after bootstrap and health check. Uses the first CP node.
# ==============================================================================

resource "talos_cluster_kubeconfig" "this" {
  count = var.control_plane_count > 0 ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane_ips[0]
  endpoint             = local.cp_endpoints[0]

  # Wait for the health check when enabled; otherwise just for the bootstrap.
  depends_on = [
    data.talos_cluster_health.this,
    talos_machine_bootstrap.this,
  ]
}
