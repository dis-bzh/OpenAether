# ==============================================================================
# Outscale — Compute Instances (VMs)
# Control planes and workers both attach to the private subnet directly and get
# an auto-assigned private IP. (A dedicated outscale_nic can't be combined with
# the VM's security_group_ids — Outscale's CreateVm rejects Nics + SG together —
# and Talos reads the actual VM IPs from the outputs, so fixed IPs aren't needed.)
# No user_data — Talos configuration is applied via the Talos API after provisioning.
# ==============================================================================

resource "outscale_vm" "control_plane" {
  count    = var.control_plane_count
  image_id = var.image_id
  vm_type  = var.instance_type

  subnet_id = outscale_subnet.private.subnet_id

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
