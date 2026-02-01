# Reserve fixed private IPs for control plane nodes via NICs
resource "outscale_nic" "control_plane" {
  count      = var.control_plane_count
  subnet_id  = var.subnet_id
  private_ips {
    is_primary = true
    private_ip = "10.0.1.${count.index + 10}" # Example predictable range
  }
}

resource "outscale_vm" "control_plane" {
  count             = var.control_plane_count
  image_id          = var.image_id
  vm_type           = var.instance_type

  nics {
    nic_id        = outscale_nic.control_plane[count.index].nic_id
    device_number = 0
  }

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-${count.index}"
  }
  tags {
    key   = "talos"
    value = "control-plane"
  }

  security_group_ids = [outscale_security_group.this.security_group_id]

  user_data = base64encode(data.talos_machine_configuration.control_plane.machine_configuration)
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

  user_data = base64encode(data.talos_machine_configuration.worker.machine_configuration)
}
