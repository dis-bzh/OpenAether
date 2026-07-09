# ==============================================================================
# Proxmox — static addressing
#
# No cloud IPAM: IPs are derived deterministically from network_cidr + offsets
# with cidrhost(). Talos consumes these as node identity IPs (50000/TCP) and the
# VIP fronts the apiserver. Egress is routed by the host bridge gateway.
# ==============================================================================

locals {
  prefix = split("/", var.network_cidr)[1]

  control_plane_ips = [
    for i in range(var.control_plane_count) :
    cidrhost(var.network_cidr, var.control_plane_ip_offset + i)
  ]

  worker_ips = [
    for i in range(var.worker_count) :
    cidrhost(var.network_cidr, var.worker_ip_offset + i)
  ]

  bastion_private_ip = cidrhost(var.network_cidr, var.bastion_ip_offset)

  # Worker × data-disk matrix (mirrors the cloud providers' worker_storage).
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key     = "w${w}-d${d}"
        worker  = w
        disk_ix = d
        size_gb = var.worker_storage.disks[d].size_gb
      }
    ]
  ])
}
