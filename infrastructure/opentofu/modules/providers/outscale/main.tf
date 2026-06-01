# ==============================================================================
# Outscale — Compute Instances (VMs)
# Control planes use NICs with fixed private IPs.
# Workers use the private subnet directly.
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

resource "outscale_nic" "control_plane" {
  count     = var.control_plane_count
  subnet_id = outscale_subnet.private.subnet_id

  security_group_ids = [outscale_security_group.this.security_group_id]

  private_ips {
    is_primary = true
  }

  tags {
    key   = "Name"
    value = "${var.cluster_name}-cp-nic-${count.index}"
  }
}

resource "outscale_vm" "control_plane" {
  count    = var.control_plane_count
  image_id = var.image_id
  vm_type  = var.instance_type

  nics {
    nic_id        = outscale_nic.control_plane[count.index].nic_id
    device_number = 0
  }

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
  image_id = var.image_id
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
