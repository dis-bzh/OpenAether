resource "outscale_load_balancer" "this" {
  load_balancer_name = "${var.cluster_name}-lb"
  listeners {
    backend_port           = 6443
    backend_protocol       = "TCP"
    load_balancer_port     = 6443
    load_balancer_protocol = "TCP"
  }
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
  subnets         = [var.subnet_id]
  security_groups = [] # Needs SG
  tags {
    key   = "Name"
    value = "${var.cluster_name}-lb"
  }
}

resource "outscale_load_balancer_vms" "backend" {
  load_balancer_name = outscale_load_balancer.this.load_balancer_name
  backend_vm_ids     = concat(outscale_vm.control_plane[*].vm_id, outscale_vm.worker[*].vm_id)
}

output "lb_ip" {
  value = outscale_load_balancer.this.dns_name
}
