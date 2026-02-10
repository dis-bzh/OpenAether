# OpenStack Octavia Load Balancer for OVH
# Requires the instances to be on a subnet that the LB can reach.

resource "openstack_lb_loadbalancer_v2" "this" {
  name           = "${var.cluster_name}-lb"
  vip_network_id = var.network_id # We might need to pass network ID instead of name, or look it up
}

resource "openstack_lb_listener_v2" "k8s_api" {
  protocol        = "TCP"
  protocol_port   = 6443
  loadbalancer_id = openstack_lb_loadbalancer_v2.this.id
  name            = "k8s-api-listener"
  allowed_cidrs   = var.admin_ip
}

resource "openstack_lb_pool_v2" "k8s_api" {
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_api.id
  name        = "k8s-api-pool"
}

resource "openstack_lb_member_v2" "control_plane" {
  count         = var.control_plane_count
  pool_id       = openstack_lb_pool_v2.k8s_api.id
  address       = openstack_compute_instance_v2.control_plane[count.index].access_ip_v4
  protocol_port = 6443
  subnet_id     = var.subnet_id
}

# --- App Traffic (HTTP/HTTPS) ---

resource "openstack_lb_listener_v2" "http" {
  protocol        = "TCP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.this.id
  name            = "http-listener"
}

resource "openstack_lb_pool_v2" "http" {
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.http.id
  name        = "http-pool"
}

resource "openstack_lb_member_v2" "worker_http" {
  count         = var.worker_count
  pool_id       = openstack_lb_pool_v2.http.id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = 80
  subnet_id     = var.subnet_id
}

resource "openstack_lb_listener_v2" "https" {
  protocol        = "TCP"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.this.id
  name            = "https-listener"
}

resource "openstack_lb_pool_v2" "https" {
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.https.id
  name        = "https-pool"
}

resource "openstack_lb_member_v2" "worker_https" {
  count         = var.worker_count
  pool_id       = openstack_lb_pool_v2.https.id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = 443
  subnet_id     = var.subnet_id
}

# Floating IP for External Access
resource "openstack_networking_floatingip_v2" "vip" {
  pool = "Ext-Net"
}

resource "openstack_networking_floatingip_associate_v2" "vip" {
  floating_ip = openstack_networking_floatingip_v2.vip.address
  port_id     = openstack_lb_loadbalancer_v2.this.vip_port_id
}

output "lb_ip" {
  value = openstack_networking_floatingip_v2.vip.address
}
