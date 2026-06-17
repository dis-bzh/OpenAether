# Access via bastion for management

# Dedicated data disks per worker (worker × disk matrix). Each worker_storage.disks
# entry becomes one SBS block volume per worker, attached via additional_volume_ids.
# Co-located in the worker's zone. iops is required for SBS volumes.
locals {
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key     = "w${w}-d${d}"
        worker  = w
        zone    = element(var.additional_zones, w)
        size_gb = var.worker_storage.disks[d].size_gb
      }
    ]
  ])
}

resource "scaleway_block_volume" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  name       = "${var.cluster_name}-worker-data-${each.value.worker}-${each.key}"
  zone       = each.value.zone
  iops       = 5000
  size_in_gb = each.value.size_gb
  tags       = ["talos", "worker-data", var.cluster_name]
}

data "scaleway_instance_image" "talos" {
  count = var.control_plane_count
  name  = var.image_name
  zone  = element(var.additional_zones, count.index)
}

data "scaleway_instance_image" "worker" {
  count = var.worker_count
  name  = var.image_name
  zone  = element(var.additional_zones, count.index)
}

resource "scaleway_instance_server" "control_plane" {
  count      = var.control_plane_count
  name       = "${var.cluster_name}-cp-${count.index}"
  type       = var.instance_type
  image      = coalesce(var.image_id, data.scaleway_instance_image.talos[count.index].id)
  zone       = element(var.additional_zones, count.index)
  project_id = var.project_id

  root_volume {
    volume_type           = var.root_volume_type
    size_in_gb            = 20
    delete_on_termination = true
  }

  # No public IP - private network only

  security_group_id = scaleway_instance_security_group.this[element(var.additional_zones, count.index)].id

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "scaleway_instance_server" "worker" {
  count      = var.worker_count
  name       = "${var.cluster_name}-worker-${count.index}"
  type       = var.instance_type
  image      = coalesce(var.image_id, data.scaleway_instance_image.worker[count.index].id)
  zone       = element(var.additional_zones, count.index)
  project_id = var.project_id

  root_volume {
    volume_type           = var.root_volume_type
    size_in_gb            = 20
    delete_on_termination = true
  }

  # Dedicated data disks for this worker (Longhorn / local-path), if any.
  additional_volume_ids = [
    for disk in local.worker_data_disks :
    scaleway_block_volume.worker_data[disk.key].id
    if disk.worker == count.index
  ]

  # No public IP - private network only

  security_group_id = scaleway_instance_security_group.this[element(var.additional_zones, count.index)].id

  tags = ["talos", "worker", var.cluster_name]
}
