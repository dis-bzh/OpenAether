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

resource "scaleway_lb_private_network" "this" {
  lb_id              = scaleway_lb.this.id
  private_network_id = scaleway_vpc_private_network.this.id

  # Optional: specify a static IP for the LB in the private net if needed,
  # or let Scaleway DHCP handle it.
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

resource "scaleway_lb_acl" "k8s_api_whitelist" {
  frontend_id = scaleway_lb_frontend.control_plane.id
  name        = "k8s_api_whitelist"
  index       = 1
  action {
    type = "allow"
  }
  match {
    ip_subnet = concat(
      var.admin_ip,
      [
        "${scaleway_vpc_public_gateway_ip.this.address}/32", # Allow nodes via NAT GW (Hairpinning)
        "172.16.0.0/12"                                     # Allow nodes directly if routed
      ]
    )
  }
  lifecycle {
    ignore_changes = [match]
  }
}

resource "scaleway_lb_acl" "k8s_api_deny_default" {
  frontend_id = scaleway_lb_frontend.control_plane.id
  name        = "k8s_api_deny_default"
  index       = 2
  action {
    type = "deny"
  }
  match {
    ip_subnet = ["0.0.0.0/0"]
  }
  lifecycle {
    ignore_changes = [match]
  }
}
# --- App Traffic (HTTP/HTTPS) ---

resource "scaleway_lb_backend" "http" {
  lb_id                  = scaleway_lb.this.id
  name                   = "http-backend"
  forward_port           = 80
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for server in scaleway_instance_server.worker : [for ip in server.private_ips : ip.address if !can(regex(":", ip.address))][0] if length(server.private_ips) > 0]
}

resource "scaleway_lb_frontend" "http" {
  lb_id        = scaleway_lb.this.id
  backend_id   = scaleway_lb_backend.http.id
  name         = "http-frontend"
  inbound_port = 80
}

resource "scaleway_lb_backend" "https" {
  lb_id                  = scaleway_lb.this.id
  name                   = "https-backend"
  forward_port           = 443
  forward_port_algorithm = "roundrobin"
  forward_protocol       = "tcp"
  server_ips             = [for server in scaleway_instance_server.worker : [for ip in server.private_ips : ip.address if !can(regex(":", ip.address))][0] if length(server.private_ips) > 0]
}

resource "scaleway_lb_frontend" "https" {
  lb_id        = scaleway_lb.this.id
  backend_id   = scaleway_lb_backend.https.id
  name         = "https-frontend"
  inbound_port = 443
}

output "lb_ip" {
  value = scaleway_lb_ip.this.ip_address
}
