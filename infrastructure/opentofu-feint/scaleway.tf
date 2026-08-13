# Scaleway fixture — the shapes modules/providers/scw builds, minus what the
# emulator does not serve (LB, public gateway, IPAM reservations, block volumes).
#
# root_volume declares no volume_type on purpose, and it is the one production
# attribute this lane cannot carry: the module asks for sbs_volume, the emulator
# answers b_ssd whatever was requested (its catalogue is fixed), and provider
# 2.80 refuses an explicit b_ssd outright. Declaring either is a permanent diff
# or an error, so the type is left to the API and stays unexercised here.

resource "scaleway_vpc_private_network" "this" {
  count = local.scaleway_active
  name  = "${var.cluster_name}-pn"

  ipv4_subnet {
    subnet = var.private_cidr
  }
}

# Inline rules, drop-by-default — rule 4 of provider-contract.md. The provider
# sends the whole list on every change, so a reordered or id-less read-back is a
# permanent diff; the empty second plan below is what proves it is not.
resource "scaleway_instance_security_group" "this" {
  count                   = local.scaleway_active
  name                    = "${var.cluster_name}-sg"
  description             = "OpenAether emulated cluster"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 6443
    ip_range = var.private_cidr
  }

  # Talos API from the bastion only, never from a load balancer.
  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 50000
    ip_range = var.private_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "UDP"
    port     = 51820
    ip_range = var.private_cidr
  }
}

resource "scaleway_instance_volume" "worker_data" {
  count      = local.scaleway_active
  name       = "${var.cluster_name}-worker-data"
  type       = "b_ssd"
  size_in_gb = 10
}

resource "scaleway_instance_server" "control_plane" {
  count             = local.scaleway_active
  name              = "${var.cluster_name}-cp-0"
  type              = "DEV1-S"
  image             = "ubuntu_jammy"
  security_group_id = scaleway_instance_security_group.this[0].id
  tags              = ["talos", "control-plane", var.cluster_name]

  root_volume {
    size_in_gb            = 20
    delete_on_termination = true
  }
}

resource "scaleway_instance_server" "worker" {
  count                 = local.scaleway_active
  name                  = "${var.cluster_name}-worker-0"
  type                  = "DEV1-S"
  image                 = "ubuntu_jammy"
  security_group_id     = scaleway_instance_security_group.this[0].id
  additional_volume_ids = [scaleway_instance_volume.worker_data[0].id]
  tags                  = ["talos", "worker", var.cluster_name]

  root_volume {
    size_in_gb            = 20
    delete_on_termination = true
  }
}

# Where the addressing plan meets the machine: the address is drawn from the
# private network's own block and read back on the NIC.
resource "scaleway_instance_private_nic" "control_plane" {
  count              = local.scaleway_active
  server_id          = scaleway_instance_server.control_plane[0].id
  private_network_id = scaleway_vpc_private_network.this[0].id
}

resource "scaleway_instance_ip" "bastion" {
  count = local.scaleway_active
  type  = "routed_ipv4"
}

resource "scaleway_instance_server" "bastion" {
  count             = local.scaleway_active
  name              = "${var.cluster_name}-bastion"
  type              = "DEV1-S"
  image             = "ubuntu_jammy"
  ip_id             = scaleway_instance_ip.bastion[0].id
  security_group_id = scaleway_instance_security_group.this[0].id
  tags              = ["bastion", var.cluster_name]

  root_volume {
    size_in_gb            = 20
    delete_on_termination = true
  }

  user_data = {
    "cloud-init" = local.bastion_cloud_init
  }
}
