# ==============================================================================
# Outscale — Load Balancers
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes
#   app: public 80/443 → the Gateway's NodePorts on the workers
# Outscale LBs return a DNS name (not IP).
# ==============================================================================

# --- Kubernetes API LB ---

resource "outscale_load_balancer" "k8s" {
  load_balancer_name = "${var.cluster_name}-k8s-lb"
  load_balancer_type = "internet-facing"

  listeners {
    backend_port           = 6443
    backend_protocol       = "TCP"
    load_balancer_port     = 6443
    load_balancer_protocol = "TCP"
  }

  subnets         = [outscale_subnet.public.subnet_id]
  security_groups = [outscale_security_group.this.security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-k8s-lb"
  }
}

# ⚠️ Outscale's health check defaults are healthy_threshold = 10 and
# check_interval = 30 s: after the slightest hiccup it takes **5 minutes** for
# a backend to come back UP — during which the Kubernetes API answers `EOF`
# (the LB accepts the connection but has no healthy backend). Observed several
# times on the Outscale management. Since `health_check` is a computed attribute
# on outscale_load_balancer, it is set through this dedicated resource.
resource "outscale_load_balancer_attributes" "k8s" {
  load_balancer_name = outscale_load_balancer.k8s.load_balancer_name

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    check_interval      = 10
    timeout             = 5
    port                = 6443
    protocol            = "TCP"
  }
}

resource "outscale_load_balancer_vms" "k8s" {
  load_balancer_name = outscale_load_balancer.k8s.load_balancer_name
  backend_vm_ids     = outscale_vm.control_plane[*].vm_id
}

# --- App LB (HTTP/HTTPS) ---

resource "outscale_load_balancer" "app" {
  load_balancer_name = "${var.cluster_name}-app-lb"
  load_balancer_type = "internet-facing"

  listeners {
    # backend_port = the Gateway's fixed NodePort; load_balancer_port stays public.
    backend_port           = var.app_lb_node_ports.http
    backend_protocol       = "TCP"
    load_balancer_port     = 80
    load_balancer_protocol = "TCP"
  }

  listeners {
    backend_port           = var.app_lb_node_ports.https
    backend_protocol       = "TCP"
    load_balancer_port     = 443
    load_balancer_protocol = "TCP"
  }

  subnets         = [outscale_subnet.public.subnet_id]
  security_groups = [outscale_security_group.this.security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-app-lb"
  }
}

resource "outscale_load_balancer_vms" "app" {
  load_balancer_name = outscale_load_balancer.app.load_balancer_name
  backend_vm_ids     = outscale_vm.worker[*].vm_id
}
