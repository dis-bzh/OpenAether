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
