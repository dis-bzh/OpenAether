resource "scaleway_lb_ip" "this" {
  zone       = var.zone
  project_id = var.project_id
}

resource "scaleway_lb" "this" {
  name       = "${var.cluster_name}-lb"
  ip_ids     = [scaleway_lb_ip.this.id]
  zone       = var.zone
  type       = "LB-S"
  project_id = var.project_id
}

resource "scaleway_lb_backend" "control_plane" {
  lb_id                  = scaleway_lb.this.id
  name                   = "control-plane-backend"
  forward_port           = 6443
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for server in scaleway_instance_server.control_plane : [for ip in server.private_ips : ip.address if !can(regex(":", ip.address))][0] if length(server.private_ips) > 0]
  
  health_check_delay       = "10s"
  health_check_timeout     = "5s"
  health_check_max_retries = 3
  health_check_port        = 6443
  health_check_tcp {}
}

resource "scaleway_lb_frontend" "control_plane" {
  lb_id        = scaleway_lb.this.id
  backend_id   = scaleway_lb_backend.control_plane.id
  name         = "control-plane-frontend"
  inbound_port = 6443
}

# ACL pour restreindre l'accès au port 6443 à l'IP admin uniquement
resource "scaleway_lb_acl" "k8s_api_whitelist" {
  frontend_id = scaleway_lb_frontend.control_plane.id
  name        = "k8s-api-whitelist"
  index       = 0

  action {
    type = "allow"
  }

  match {
    ip_subnet = [var.admin_ip]
  }
}

# ACL par défaut : deny all other traffic
resource "scaleway_lb_acl" "k8s_api_deny" {
  frontend_id = scaleway_lb_frontend.control_plane.id
  name        = "k8s-api-deny-default"
  index       = 1

  action {
    type = "deny"
  }

  match {
    ip_subnet = ["0.0.0.0/0"]
  }
}

output "lb_ip" {
  value = scaleway_lb_ip.this.ip_address
}
