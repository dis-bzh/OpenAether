# ==============================================================================
# OVH / OpenStack — Bastion Host
# Private network only + floating IP for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

data "openstack_images_image_v2" "bastion" {
  name        = var.bastion_image_id
  most_recent = true
  visibility  = "public"
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name                 = "${var.cluster_name}-bastion-sg"
  description          = "OpenAether bastion — SSH from admin IPs only"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each = toset(var.admin_ip)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_port_v2" "bastion" {
  name               = "${var.cluster_name}-bastion-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]
}

resource "openstack_compute_instance_v2" "bastion" {
  name        = "${var.cluster_name}-bastion"
  image_id    = data.openstack_images_image_v2.bastion.id
  flavor_name = "b2-7"

  network {
    port = openstack_networking_port_v2.bastion.id
  }

  user_data = <<-EOT
    #cloud-config
    ssh_authorized_keys:
      - ${var.bastion_ssh_key}
    packages:
      - netcat-openbsd
      - tcpdump
  EOT

  tags = ["bastion", var.cluster_name]
}

resource "openstack_networking_floatingip_v2" "bastion" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "bastion" {
  floating_ip = openstack_networking_floatingip_v2.bastion.address
  port_id     = openstack_networking_port_v2.bastion.id
}
