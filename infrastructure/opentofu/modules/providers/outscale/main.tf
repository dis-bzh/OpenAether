# ==============================================================================
# Outscale — Compute Instances (VMs)
# Control planes and workers both attach to the private subnet directly and get
# an auto-assigned private IP. (A dedicated outscale_nic can't be combined with
# the VM's security_group_ids — Outscale's CreateVm rejects Nics + SG together —
# and Talos reads the actual VM IPs from the outputs, so fixed IPs aren't needed.)
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

# Looked up by name only when image_id is left unset — mirrors the Scaleway
# module's data.scaleway_instance_image (the talos-image root publishes under
# this same name convention; see talos-image/main.tf's local.image_name).
# NOT validated against a real Outscale account yet — confirm the `images[0]`
# shape (most-recent-first ordering, image_id attribute) before relying on it.
data "outscale_images" "talos" {
  count = var.image_id == null ? 1 : 0
  filter {
    name   = "image_names"
    values = [var.image_name]
  }
}

locals {
  resolved_image_id = coalesce(var.image_id, try(data.outscale_images.talos[0].images[0].image_id, null))
}

resource "outscale_vm" "control_plane" {
  count    = var.control_plane_count
  image_id = local.resolved_image_id
  vm_type  = var.instance_type

  subnet_id = outscale_subnet.private.subnet_id

  security_group_ids = [outscale_security_group.this.security_group_id]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-${count.index}"
  }
  tags {
    key   = "talos"
    value = "control-plane"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

resource "outscale_vm" "worker" {
  count    = var.worker_count
  image_id = local.resolved_image_id
  vm_type  = var.instance_type

  subnet_id = outscale_subnet.private.subnet_id

  security_group_ids = [outscale_security_group.this.security_group_id]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-${count.index}"
  }
  tags {
    key   = "talos"
    value = "worker"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

# ==============================================================================
# Dedicated data disks per worker (worker × disk matrix). Each worker_storage.disks
# entry becomes one BSU volume per worker, linked to the VM. device_name follows
# the disk index (/dev/sdb, /dev/sdc, …). Volumes live in the workers' subregion
# (the private subnet's AZ). Used for Longhorn / local-path (Talos mounts under
# /var/mnt via UserVolumeConfig).
# ==============================================================================

locals {
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key         = "w${w}-d${d}"
        worker      = w
        disk_index  = d
        size_gb     = var.worker_storage.disks[d].size_gb
        device_name = "/dev/sd${substr("bcdefghijklmnop", d, 1)}"
      }
    ]
  ])
}

resource "outscale_volume" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  subregion_name = var.availability_zones[0]
  size           = each.value.size_gb

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-data-${each.value.worker}-${each.key}"
  }
  tags {
    key   = "cluster"
    value = var.cluster_name
  }
}

resource "outscale_volume_link" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  device_name = each.value.device_name
  volume_id   = outscale_volume.worker_data[each.key].volume_id
  vm_id       = outscale_vm.worker[each.value.worker].vm_id
}
