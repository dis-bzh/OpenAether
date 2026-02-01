resource "openstack_compute_instance_v2" "control_plane" {
  count       = var.control_plane_count
  name        = "${var.cluster_name}-cp-${count.index}"
  image_id    = var.image_id
  flavor_name = var.flavor_name
  region      = var.region

  network {
    name = var.network_name
  }

  user_data = var.control_plane_config

  security_groups = [openstack_networking_secgroup_v2.this.name]

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "openstack_compute_instance_v2" "worker" {
  count       = var.worker_count
  name        = "${var.cluster_name}-worker-${count.index}"
  image_id    = var.image_id
  flavor_name = var.flavor_name
  region      = var.region

  network {
    name = var.network_name
  }

  user_data = var.worker_config

  security_groups = [openstack_networking_secgroup_v2.this.name]

  tags = ["talos", "worker", var.cluster_name]
}
