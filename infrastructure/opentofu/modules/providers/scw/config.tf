data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = var.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        certSANs = concat(
          ["127.0.0.1", "localhost"],
          [for ip in scaleway_ipam_ip.control_plane : ip.address]
        )
        install = {
          disk = "/dev/vda"
          wipe = true
          image = "ghcr.io/siderolabs/installer:v1.12.0"
          grubUseUKICmdline = true
        }
        network = {
          interfaces = [
            {
              interface = "eth1"
              dhcp      = true
            }
          ]
        }
        kubelet = {
          defaultRuntimeSeccompProfileEnabled = true
          disableManifestsDirectory           = true
        }
        features = {
          diskQuotaSupport = true
          kubePrism = {
            enabled = true
            port    = 7445
          }
          hostDNS = {
            enabled              = true
            forwardKubeDNSToHost = true
          }
        }
        nodeLabels = {
          "node.kubernetes.io/exclude-from-external-load-balancers" = ""
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
        inlineManifests = [
          {
            name = "cilium"
            contents = join("---\n", var.extra_manifests)
          }
        ]
        apiServer = {
          admissionControl = [
            {
              name = "PodSecurity"
              configuration = {
                apiVersion = "pod-security.admission.config.k8s.io/v1alpha1"
                kind       = "PodSecurityConfiguration"
                defaults = {
                  audit           = "restricted"
                  audit-version   = "latest"
                  enforce         = "baseline"
                  enforce-version = "latest"
                  warn            = "restricted"
                  warn-version    = "latest"
                }
                exemptions = {
                  namespaces = ["kube-system"]
                }
              }
            }
          ]
          auditPolicy = {
            apiVersion = "audit.k8s.io/v1"
            kind       = "Policy"
            rules = [
              {
                level = "Metadata"
              }
            ]
          }
        }
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = var.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda"
          wipe = true
          image = "ghcr.io/siderolabs/installer:v1.12.0"
        }
        network = {
          interfaces = [
            {
              interface = "eth1"
              dhcp      = true
            }
          ]
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
