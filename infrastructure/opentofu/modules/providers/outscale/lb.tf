# ==============================================================================
# Outscale — Load Balancers
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes
#   app: ports 80/443 → workers
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

  subnets         = [outscale_subnet.private.subnet_id]
  security_groups = [outscale_security_group.this.security_group_id]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-k8s-lb"
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
    backend_port           = 80
    backend_protocol       = "TCP"
    load_balancer_port     = 80
    load_balancer_protocol = "TCP"
  }

  listeners {
    backend_port           = 443
    backend_protocol       = "TCP"
    load_balancer_port     = 443
    load_balancer_protocol = "TCP"
  }

  subnets         = [outscale_subnet.private.subnet_id]
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
