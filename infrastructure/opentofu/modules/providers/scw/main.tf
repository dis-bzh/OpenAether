# Public IPs removed for security - nodes use private IPs only
# Access via bastion for management

resource "scaleway_instance_server" "control_plane" {
  count      = var.control_plane_count
  name       = "${var.cluster_name}-cp-${count.index}"
  type       = var.instance_type
  image      = var.image_id
  zone       = var.zone
  project_id = var.project_id
  
  root_volume {
    size_in_gb = 40
    delete_on_termination = true
  }

  # No public IP - private network only

  # User data for Talos config
  user_data = {
    "cloud-init" = var.control_plane_config
  }

  security_group_id = scaleway_instance_security_group.this.id

  tags = ["talos", "control-plane", var.cluster_name]
}

resource "scaleway_instance_server" "worker" {
  count      = var.worker_count
  name       = "${var.cluster_name}-worker-${count.index}"
  type       = var.instance_type
  image      = var.image_id
  zone       = var.zone
  project_id = var.project_id

  root_volume {
    size_in_gb = 40
    delete_on_termination = true
  }

  # No public IP - private network only

  # User data for Talos config
  user_data = {
    "cloud-init" = var.worker_config
  }

  security_group_id = scaleway_instance_security_group.this.id

  tags = ["talos", "worker", var.cluster_name]
}
