# Reserve fixed private IPs for control plane nodes
resource "openstack_networking_port_v2" "control_plane" {
  count          = var.control_plane_count
  name           = "${var.cluster_name}-cp-port-${count.index}"
  network_id     = var.network_id
  admin_state_up = "true"
  security_group_ids = [openstack_networking_secgroup_v2.this.id]
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

  user_data = data.talos_machine_configuration.control_plane.machine_configuration

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

  user_data = data.talos_machine_configuration.worker.machine_configuration

  security_groups = [openstack_networking_secgroup_v2.this.name]

  tags = ["talos", "worker", var.cluster_name]
}
