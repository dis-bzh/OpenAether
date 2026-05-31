# ==============================================================================
# OVH / OpenStack — Load Balancers (Octavia)
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes (allowed_cidrs = admin_ip)
#   app: ports 80/443 → workers (open)
# ==============================================================================

# --- Kubernetes API LB ---

resource "openstack_lb_loadbalancer_v2" "k8s" {
  name          = "${var.cluster_name}-k8s-lb"
  vip_subnet_id = openstack_networking_subnet_v2.private.id
}

resource "openstack_lb_listener_v2" "k8s_api" {
  name            = "k8s-api"
  protocol        = "TCP"
  protocol_port   = 6443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s.id
  allowed_cidrs   = concat(var.admin_ip, ["10.0.0.0/24"])
}

resource "openstack_lb_pool_v2" "k8s_api" {
  name        = "k8s-api"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_api.id
}

resource "openstack_lb_monitor_v2" "k8s_api" {
  pool_id     = openstack_lb_pool_v2.k8s_api.id
  type        = "TCP"
  delay       = 15
  timeout     = 10
  max_retries = 5
}

resource "openstack_lb_member_v2" "k8s_api" {
  count         = var.control_plane_count
  pool_id       = openstack_lb_pool_v2.k8s_api.id
  address       = try(openstack_networking_port_v2.control_plane[count.index].all_fixed_ips[0], "0.0.0.0")
  protocol_port = 6443
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "k8s" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "k8s" {
  floating_ip = openstack_networking_floatingip_v2.k8s.address
  port_id     = openstack_lb_loadbalancer_v2.k8s.vip_port_id
}

# --- App LB (HTTP/HTTPS) ---

resource "openstack_lb_loadbalancer_v2" "app" {
  name          = "${var.cluster_name}-app-lb"
  vip_subnet_id = openstack_networking_subnet_v2.private.id
}

resource "openstack_lb_listener_v2" "http" {
  name            = "http"
  protocol        = "TCP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.app.id
}

resource "openstack_lb_pool_v2" "http" {
  name        = "http"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.http.id
}

resource "openstack_lb_member_v2" "http" {
  count         = var.worker_count
  pool_id       = openstack_lb_pool_v2.http.id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = 80
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_lb_listener_v2" "https" {
  name            = "https"
  protocol        = "TCP"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.app.id
}

resource "openstack_lb_pool_v2" "https" {
  name        = "https"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.https.id
}

resource "openstack_lb_member_v2" "https" {
  count         = var.worker_count
  pool_id       = openstack_lb_pool_v2.https.id
  address       = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  protocol_port = 443
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "app" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "app" {
  floating_ip = openstack_networking_floatingip_v2.app.address
  port_id     = openstack_lb_loadbalancer_v2.app.vip_port_id
}
