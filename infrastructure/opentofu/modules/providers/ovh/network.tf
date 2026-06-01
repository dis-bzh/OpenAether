# ==============================================================================
# OVH / OpenStack — Network
# Private network + router → Ext-Net for outbound NAT.
# Nodes have no public IP; bastion provides admin access.
# ==============================================================================

# External network (OVH "Ext-Net")
data "openstack_networking_network_v2" "ext" {
  name = var.network_name
}

# Private network for cluster nodes
resource "openstack_networking_network_v2" "private" {
  name           = "${var.cluster_name}-private"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = "${var.cluster_name}-private-subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = "10.0.0.0/24"
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
}

# Router bridges private network to Ext-Net (enables outbound NAT/SNAT)
resource "openstack_networking_router_v2" "this" {
  name                = "${var.cluster_name}-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.ext.id
}

resource "openstack_networking_router_interface_v2" "private" {
  router_id = openstack_networking_router_v2.this.id
  subnet_id = openstack_networking_subnet_v2.private.id
}
