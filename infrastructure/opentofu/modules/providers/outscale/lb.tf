# ==============================================================================
# Outscale — Load Balancers
# Two separate LBs matching the provider contract:
#   k8s: port 6443 → control planes
#   app: 80/443 en public → NodePorts du Gateway sur les workers
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

# ⚠️ Les défauts Outscale du health check sont healthy_threshold = 10 et
# check_interval = 30 s : après le moindre hoquet, il faut **5 minutes** pour
# qu'un backend redevienne UP — pendant lesquelles l'API Kubernetes répond
# `EOF` (le LB accepte la connexion mais n'a aucun backend sain). Observé
# plusieurs fois sur le management Outscale. `health_check` étant un attribut
# calculé sur outscale_load_balancer, il se règle via cette ressource dédiée.
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
    # backend_port = NodePort figé du Gateway ; load_balancer_port reste public.
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
