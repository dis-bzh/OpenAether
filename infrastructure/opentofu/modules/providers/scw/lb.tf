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
# LB Kubernetes API (permanent) — Port 6443 only
# Always active. No 50000/TCP — Talos API is accessed via bastion tunnel.
# ACL-restricted to admin_ip + private network ranges.
# ==============================================================================

resource "scaleway_lb_ip" "k8s" {
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "k8s" {
  name       = "${var.cluster_name}-k8s-lb"
  ip_ids     = [scaleway_lb_ip.k8s.id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id
}

resource "scaleway_lb_private_network" "k8s" {
  lb_id              = scaleway_lb.k8s.id
  private_network_id = scaleway_vpc_private_network.this.id
}

# --- K8s API backend (6443) ---

resource "scaleway_lb_backend" "k8s_api" {
  lb_id                  = scaleway_lb.k8s.id
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
  lb_id        = scaleway_lb.k8s.id
  backend_id   = scaleway_lb_backend.k8s_api.id
  name         = "k8s-api-frontend"
  inbound_port = 6443
}

# --- ACLs K8s API LB (admin_ip only + private subnets) ---

resource "scaleway_lb_acl" "k8s_whitelist" {
  frontend_id = scaleway_lb_frontend.k8s_api.id
  name        = "k8s-api-whitelist"
  index       = 1
  action { type = "allow" }
  match {
    ip_subnet = concat(var.admin_ip, ["172.16.0.0/12", "10.0.0.0/8"])
  }
}

resource "scaleway_lb_acl" "k8s_deny" {
  frontend_id = scaleway_lb_frontend.k8s_api.id
  name        = "k8s-api-deny"
  index       = 2
  action { type = "deny" }
  match { ip_subnet = ["0.0.0.0/0"] }
}
