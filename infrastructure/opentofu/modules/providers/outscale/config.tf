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
          [for n in outscale_nic.control_plane : n.private_ips[0].private_ip]
        )
        install = {
          disk = "/dev/vda"
          wipe = true
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
}
