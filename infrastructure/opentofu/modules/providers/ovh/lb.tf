# ==============================================================================
# OVH / OpenStack — Load Balancers (Octavia)
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes (allowed_cidrs = admin_ip)
#   app: 80/443 en public → NodePorts du Gateway sur les workers (open)
# ==============================================================================

# --- Kubernetes API LB ---
# Only created when k8s_lb_mode = "managed" (default). In "vip" mode the API
# is fronted by a Talos Layer2 VIP instead (k8s_vip port below) — no LB, no
# floating IP.

resource "openstack_lb_loadbalancer_v2" "k8s" {
  count         = var.k8s_lb_mode == "managed" ? 1 : 0
  name          = "${var.cluster_name}-k8s-lb"
  vip_subnet_id = openstack_networking_subnet_v2.private.id
}

resource "openstack_lb_listener_v2" "k8s_api" {
  count           = var.k8s_lb_mode == "managed" ? 1 : 0
  name            = "k8s-api"
  protocol        = "TCP"
  protocol_port   = 6443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s[0].id
  allowed_cidrs   = concat(var.admin_ip, ["10.0.0.0/24"])
}

resource "openstack_lb_pool_v2" "k8s_api" {
  count       = var.k8s_lb_mode == "managed" ? 1 : 0
  name        = "k8s-api"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_api[0].id
}

resource "openstack_lb_monitor_v2" "k8s_api" {
  count       = var.k8s_lb_mode == "managed" ? 1 : 0
  pool_id     = openstack_lb_pool_v2.k8s_api[0].id
  type        = "TCP"
  delay       = 15
  timeout     = 10
  max_retries = 5
}

resource "openstack_lb_member_v2" "k8s_api" {
  count         = var.k8s_lb_mode == "managed" ? var.control_plane_count : 0
  pool_id       = openstack_lb_pool_v2.k8s_api[0].id
  address       = try(openstack_networking_port_v2.control_plane[count.index].all_fixed_ips[0], "0.0.0.0")
  protocol_port = 6443
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "k8s" {
  count = var.k8s_lb_mode == "managed" ? 1 : 0
  pool  = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "k8s" {
  count       = var.k8s_lb_mode == "managed" ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.k8s[0].address
  port_id     = openstack_lb_loadbalancer_v2.k8s[0].vip_port_id

  # ⚠️ depends_on OBLIGATOIRE sur l'interface du routeur. Neutron REFUSE
  # d'associer une floating IP tant que le subnet du port n'a pas de route vers
  # le réseau externe :
  #   ExternalGatewayForFloatingIPNotFound: External network <id> is not
  #   reachable from subnet <id>
  # Aucune référence ne lie ces deux ressources, donc OpenTofu les crée en
  # PARALLÈLE → échec INTERMITTENT selon qui gagne la course. Constaté le
  # 2026-07-28 sur le bastion ; les deux LB passaient jusque-là par chance, un
  # load balancer étant plus lent à créer.
  depends_on = [openstack_networking_router_interface_v2.private]
}

# --- apiserver VIP (k8s_lb_mode = "vip") ---
# Detached port on the private subnet: not bound to any instance, it only
# reserves the address. Talos claims it via gratuitous ARP on whichever
# control plane currently holds it (see the allowed_address_pairs on each CP
# port in main.tf).

resource "openstack_networking_port_v2" "k8s_vip" {
  count              = var.k8s_lb_mode == "vip" ? 1 : 0
  name               = "${var.cluster_name}-k8s-vip-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.this.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
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
  count   = var.worker_count
  pool_id = openstack_lb_pool_v2.http.id
  address = openstack_compute_instance_v2.worker[count.index].access_ip_v4
  # NodePort figé du Gateway ; le listener public reste sur 80.
  protocol_port = var.app_lb_node_ports.http
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
  protocol_port = var.app_lb_node_ports.https
  subnet_id     = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_floatingip_v2" "app" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "app" {
  floating_ip = openstack_networking_floatingip_v2.app.address
  port_id     = openstack_lb_loadbalancer_v2.app.vip_port_id

  # ⚠️ depends_on OBLIGATOIRE sur l'interface du routeur. Neutron REFUSE
  # d'associer une floating IP tant que le subnet du port n'a pas de route vers
  # le réseau externe :
  #   ExternalGatewayForFloatingIPNotFound: External network <id> is not
  #   reachable from subnet <id>
  # Aucune référence ne lie ces deux ressources, donc OpenTofu les crée en
  # PARALLÈLE → échec INTERMITTENT selon qui gagne la course. Constaté le
  # 2026-07-28 sur le bastion ; les deux LB passaient jusque-là par chance, un
  # load balancer étant plus lent à créer.
  depends_on = [openstack_networking_router_interface_v2.private]
}
