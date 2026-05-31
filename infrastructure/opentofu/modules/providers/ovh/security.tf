# ==============================================================================
# OVH / OpenStack — Security Groups
# inbound_default = drop (delete_default_rules). Only required ports opened.
#
# OVH Octavia health checks originate from the LB VIP subnet CIDR.
# We allow the full private subnet (10.0.0.0/24) for LB + inter-node traffic.
# K8s API is further restricted by the Octavia listener allowed_cidrs.
# ==============================================================================

resource "openstack_networking_secgroup_v2" "this" {
  name                 = "${var.cluster_name}-cluster-sg"
  description          = "OpenAether cluster nodes — least-privilege inbound"
  delete_default_rules = true
}

# Kubernetes API — from private subnet (LB health checks + inter-node)
# Additional restriction enforced at LB listener level (allowed_cidrs)
resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Talos API — from bastion security group only
resource "openstack_networking_secgroup_rule_v2" "talos_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50000
  remote_group_id   = openstack_networking_secgroup_v2.bastion.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# HTTP/HTTPS — from private subnet (App LB health checks)
resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# WireGuard — Cilium inter-node encryption (UDP 51820)
resource "openstack_networking_secgroup_rule_v2" "wireguard" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 51820
  port_range_max    = 51820
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Inter-node — full mesh TCP (etcd, kubelet, Cilium)
resource "openstack_networking_secgroup_rule_v2" "inter_node" {
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Outbound — allow all
resource "openstack_networking_secgroup_rule_v2" "egress_v4" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_v6" {
  direction         = "egress"
  ethertype         = "IPv6"
  security_group_id = openstack_networking_secgroup_v2.this.id
}
