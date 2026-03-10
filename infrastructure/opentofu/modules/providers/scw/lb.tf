# ==============================================================================
# LB App (permanent) — Ports 80/443 pour les applications via Ingress Controller
# ==============================================================================

resource "scaleway_lb_ip" "app" {
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "app" {
  name       = "${var.cluster_name}-app-lb"
  ip_ids     = [scaleway_lb_ip.app.id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id
}

resource "scaleway_lb_private_network" "app" {
  lb_id              = scaleway_lb.app.id
  private_network_id = scaleway_vpc_private_network.this.id
}

resource "scaleway_lb_backend" "http" {
  lb_id                  = scaleway_lb.app.id
  name                   = "http-backend"
  forward_port           = 80
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.worker : ip.address]
}

resource "scaleway_lb_frontend" "http" {
  lb_id        = scaleway_lb.app.id
  backend_id   = scaleway_lb_backend.http.id
  name         = "http-frontend"
  inbound_port = 80
}

resource "scaleway_lb_backend" "https" {
  lb_id                  = scaleway_lb.app.id
  name                   = "https-backend"
  forward_port           = 443
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.worker : ip.address]
}

resource "scaleway_lb_frontend" "https" {
  lb_id        = scaleway_lb.app.id
  backend_id   = scaleway_lb_backend.https.id
  name         = "https-frontend"
  inbound_port = 443
}

# ==============================================================================
# LB Admin (éphémère) — Ports 6443/50000 pour bootstrap et maintenance
# Contrôlé par var.admin_lb_enabled
# ==============================================================================

resource "scaleway_lb_ip" "admin" {
  count      = var.admin_lb_enabled ? 1 : 0
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "admin" {
  count      = var.admin_lb_enabled ? 1 : 0
  name       = "${var.cluster_name}-admin-lb"
  ip_ids     = [scaleway_lb_ip.admin[0].id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id
}

resource "scaleway_lb_private_network" "admin" {
  count              = var.admin_lb_enabled ? 1 : 0
  lb_id              = scaleway_lb.admin[0].id
  private_network_id = scaleway_vpc_private_network.this.id
}

# --- K8s API (6443) ---

resource "scaleway_lb_backend" "k8s_api" {
  count                  = var.admin_lb_enabled ? 1 : 0
  lb_id                  = scaleway_lb.admin[0].id
  name                   = "k8s-api-backend"
  forward_port           = 6443
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.control_plane : ip.address]

  health_check_delay       = "15s"
  health_check_timeout     = "10s"
  health_check_max_retries = 5
  health_check_port        = 6443
  health_check_tcp {}
}

resource "scaleway_lb_frontend" "k8s_api" {
  count        = var.admin_lb_enabled ? 1 : 0
  lb_id        = scaleway_lb.admin[0].id
  backend_id   = scaleway_lb_backend.k8s_api[0].id
  name         = "k8s-api-frontend"
  inbound_port = 6443
}

# --- Talos API (50000) ---

resource "scaleway_lb_backend" "talos_api" {
  count                  = var.admin_lb_enabled ? 1 : 0
  lb_id                  = scaleway_lb.admin[0].id
  name                   = "talos-api-backend"
  forward_port           = 50000
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for ip in scaleway_ipam_ip.control_plane : ip.address]

  health_check_delay       = "15s"
  health_check_timeout     = "10s"
  health_check_max_retries = 5
  health_check_port        = 50000
  health_check_tcp {}
}

resource "scaleway_lb_frontend" "talos_api" {
  count        = var.admin_lb_enabled ? 1 : 0
  lb_id        = scaleway_lb.admin[0].id
  backend_id   = scaleway_lb_backend.talos_api[0].id
  name         = "talos-api-frontend"
  inbound_port = 50000
}

# --- ACLs Admin LB (admin_ip only) ---

resource "scaleway_lb_acl" "admin_k8s_whitelist" {
  count       = var.admin_lb_enabled ? 1 : 0
  frontend_id = scaleway_lb_frontend.k8s_api[0].id
  name        = "admin-k8s-whitelist"
  index       = 1
  action { type = "allow" }
  match {
    ip_subnet = concat(var.admin_ip, ["172.16.0.0/12"])
  }
}

resource "scaleway_lb_acl" "admin_k8s_deny" {
  count       = var.admin_lb_enabled ? 1 : 0
  frontend_id = scaleway_lb_frontend.k8s_api[0].id
  name        = "admin-k8s-deny"
  index       = 2
  action { type = "deny" }
  match { ip_subnet = ["0.0.0.0/0"] }
}

resource "scaleway_lb_acl" "admin_talos_whitelist" {
  count       = var.admin_lb_enabled ? 1 : 0
  frontend_id = scaleway_lb_frontend.talos_api[0].id
  name        = "admin-talos-whitelist"
  index       = 1
  action { type = "allow" }
  match {
    ip_subnet = concat(var.admin_ip, ["172.16.0.0/12"])
  }
}

resource "scaleway_lb_acl" "admin_talos_deny" {
  count       = var.admin_lb_enabled ? 1 : 0
  frontend_id = scaleway_lb_frontend.talos_api[0].id
  name        = "admin-talos-deny"
  index       = 2
  action { type = "deny" }
  match { ip_subnet = ["0.0.0.0/0"] }
}

# ==============================================================================
# Outputs
# ==============================================================================

output "app_lb_ip" {
  value       = scaleway_lb_ip.app.ip_address
  description = "Public IP of the permanent app LB (80/443)"
}

output "admin_lb_ip" {
  value       = var.admin_lb_enabled ? scaleway_lb_ip.admin[0].ip_address : null
  description = "Public IP of the ephemeral admin LB (6443/50000). Null when disabled."
}
