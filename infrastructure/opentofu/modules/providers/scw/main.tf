# Access via bastion for management

data "scaleway_instance_image" "talos" {
  count = var.control_plane_count
  name  = var.image_name
  zone  = element(var.additional_zones, count.index)
}

data "scaleway_instance_image" "worker" {
  count = var.worker_count
  name  = var.image_name
  zone  = var.zone
}

resource "scaleway_instance_server" "control_plane" {
  count      = var.control_plane_count
  name       = "${var.cluster_name}-cp-${count.index}"
  type       = var.instance_type
  image      = coalesce(var.image_id, data.scaleway_instance_image.talos[count.index].id)
  zone       = element(var.additional_zones, count.index)
  project_id = var.project_id
  
  root_volume {
    size_in_gb = 20
    delete_on_termination = true
  }

  # No public IP - private network only

  # User data for Talos config
  user_data = {
    "cloud-init" = data.talos_machine_configuration.control_plane.machine_configuration
  }

  security_group_id = scaleway_instance_security_group.this[element(var.additional_zones, count.index)].id

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "scaleway_instance_server" "worker" {
  count      = var.worker_count
  name       = "${var.cluster_name}-worker-${count.index}"
  type       = var.instance_type
  image      = coalesce(var.image_id, data.scaleway_instance_image.worker[count.index].id)
  zone       = var.zone
  project_id = var.project_id

  root_volume {
    size_in_gb = 20
    delete_on_termination = true
  }

  # No public IP - private network only

  # User data for Talos config
  user_data = {
    "cloud-init" = data.talos_machine_configuration.worker.machine_configuration
  }

  security_group_id = scaleway_instance_security_group.this[var.zone].id

  tags = ["talos", "worker", var.cluster_name]
}
