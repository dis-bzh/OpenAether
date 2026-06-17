# ==============================================================================
# OVH / OpenStack — Compute Instances
# Control planes use port-based networking for fixed private IPs.
# Workers use network name (dynamic IP within private subnet).
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

resource "openstack_networking_port_v2" "control_plane" {
  count              = var.control_plane_count
  name               = "${var.cluster_name}-cp-port-${count.index}"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.this.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_compute_instance_v2" "control_plane" {
  count             = var.control_plane_count
  name              = "${var.cluster_name}-cp-${count.index}"
  image_id          = var.image_id
  flavor_name       = var.flavor_name
  region            = var.region
  availability_zone = element(var.availability_zones, count.index)

  network {
    port = openstack_networking_port_v2.control_plane[count.index].id
  }

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "openstack_compute_instance_v2" "worker" {
  count             = var.worker_count
  name              = "${var.cluster_name}-worker-${count.index}"
  image_id          = var.image_id
  flavor_name       = var.flavor_name
  region            = var.region
  availability_zone = element(var.availability_zones, count.index)

  network {
    uuid = openstack_networking_network_v2.private.id
  }

  security_groups = [openstack_networking_secgroup_v2.this.name]

  # No user_data — Talos configuration applied via Talos API by modules/talos/

  tags = ["talos", "worker", var.cluster_name]
}

# ==============================================================================
# Dedicated data disks per worker (worker × disk matrix). Each worker_storage.disks
# entry becomes one Cinder block volume per worker, attached to the instance.
# Used for Longhorn / local-path (Talos UserVolumeConfig mounts them at /var/mnt).
# ==============================================================================

locals {
  worker_data_disks = flatten([
    for w in range(var.worker_count) : [
      for d in range(length(var.worker_storage.disks)) : {
        key     = "w${w}-d${d}"
        worker  = w
        size_gb = var.worker_storage.disks[d].size_gb
      }
    ]
  ])
}

resource "openstack_blockstorage_volume_v3" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  name   = "${var.cluster_name}-worker-data-${each.value.worker}-${each.key}"
  region = var.region
  size   = each.value.size_gb
}

resource "openstack_compute_volume_attach_v2" "worker_data" {
  for_each = { for disk in local.worker_data_disks : disk.key => disk }

  instance_id = openstack_compute_instance_v2.worker[each.value.worker].id
  volume_id   = openstack_blockstorage_volume_v3.worker_data[each.key].id
}
