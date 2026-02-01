resource "outscale_vm" "control_plane" {
  count     = var.control_plane_count
  image_id  = var.image_id
  vm_type   = var.instance_type
  subnet_id = var.subnet_id


  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-${count.index}"
  }
  tags {
    key   = "talos"
    value = "control-plane"
  }

  security_group_ids = [outscale_security_group.this.security_group_id]

  user_data = base64encode(var.control_plane_config)
}

resource "outscale_public_ip" "control_plane" {
  count = var.control_plane_count
}

resource "outscale_public_ip_link" "control_plane" {
  count     = var.control_plane_count
  vm_id     = outscale_vm.control_plane[count.index].vm_id
  public_ip = outscale_public_ip.control_plane[count.index].public_ip
}

resource "outscale_vm" "worker" {
  count     = var.worker_count
  image_id  = var.image_id
  vm_type   = var.instance_type
  subnet_id = var.subnet_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-worker-${count.index}"
  }
  tags {
    key   = "talos"
    value = "worker"
  }

  security_group_ids = [outscale_security_group.this.security_group_id]

  user_data = base64encode(var.worker_config)
}

resource "outscale_public_ip" "worker" {
  count = var.worker_count
}

resource "outscale_public_ip_link" "worker" {
  count     = var.worker_count
  vm_id     = outscale_vm.worker[count.index].vm_id
  public_ip = outscale_public_ip.worker[count.index].public_ip
}
