resource "openstack_networking_secgroup_v2" "this" {
  name        = "${var.cluster_name}-sg"
  description = "Security Group for OpenAether Talos Cluster"
}

# Kubernetes API (TCP 6443) - Restricted to LB for defense in depth
resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "${openstack_networking_floatingip_v2.vip.address}/32"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Talos API (TCP 50000) - Restricted to Bastion (if exists) or Admin
resource "openstack_networking_secgroup_rule_v2" "talos_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50000
  remote_ip_prefix  = "0.0.0.0/0" # TODO: Restrict to Bastion after implementation
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# HTTP/HTTPS - Open via LB
resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "${openstack_networking_floatingip_v2.vip.address}/32"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "${openstack_networking_floatingip_v2.vip.address}/32"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# WireGuard / Cilium (UDP 51820)
resource "openstack_networking_secgroup_rule_v2" "wireguard" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 51820
  port_range_max    = 51820
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.this.id
}

# Internal Traffic (Allow all from self)
resource "openstack_networking_secgroup_rule_v2" "internal" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp" # Or explicitly match rules, but self-referencing SG is cleaner if supported
  remote_group_id   = openstack_networking_secgroup_v2.this.id
  security_group_id = openstack_networking_secgroup_v2.this.id
}
