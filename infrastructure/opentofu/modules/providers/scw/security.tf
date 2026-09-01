# Security Groups — Least-privilege inbound, permissive outbound
#
# Network access strategy:
#   - 6443/TCP: Kubernetes API via K8s LB (permanent)
#   - 50000/TCP: Talos API — the bastion reaches nodes over its PRIVATE NIC, so
#                this is admitted by the private-subnet mesh rule below, not a
#                dedicated bastion rule. Never exposed via Load Balancers.
#   - NodePorts 30080/30443: application traffic from the App LB (deploy_app_lb only)
#   - Inter-node: full mesh on the module's own private subnet
# ==============================================================================

resource "scaleway_instance_security_group" "this" {
  for_each    = toset(var.additional_zones)
  name        = "${var.cluster_name}-sg-${each.key}"
  description = "Security Group for OpenAether Talos Cluster in ${each.key}"

  inbound_default_policy = "drop"

  # Kubernetes API — From K8s LB (managed mode only; in vip mode the apiserver
  # VIP lives directly on a control plane's private interface — there is no
  # LB IP to allow here, and inter-node/private-subnet rules below already
  # cover VIP traffic on the private network).
  dynamic "inbound_rule" {
    for_each = var.k8s_lb_mode == "managed" ? [1] : []
    content {
      action   = "accept"
      port     = 6443
      ip_range = "${scaleway_lb_ip.k8s[0].ip_address}/32"
      protocol = "TCP"
    }
  }

  # Kubernetes API — From App LB (for internal service communication).
  # Only when that LB exists (deploy_app_lb): no LB, no source IP to allow.
  dynamic "inbound_rule" {
    for_each = var.deploy_app_lb ? [1] : []
    content {
      action   = "accept"
      port     = 6443
      ip_range = "${scaleway_lb_ip.app[0].ip_address}/32"
      protocol = "TCP"
    }
  }

  # Inter-node mesh, scoped to this module's own pinned subnet (network.tf) —
  # also what admits 50000/TCP (Talos API) from the bastion's private NIC now.
  inbound_rule {
    action   = "accept"
    ip_range = local.scw_cluster_subnet
    protocol = "ANY"
  }

  # Scaleway internal / LB health checks — not this module's subnet, left as-is.
  inbound_rule {
    action   = "accept"
    ip_range = "100.64.0.0/10"
    protocol = "ANY"
  }

  # HTTP/HTTPS — from the App LB, on the Gateway's FIXED NodePorts.
  # (The LB listens on public 80/443 and forwards to those worker-side ports;
  # opening 80/443 here would achieve nothing — nothing listens on the nodes.)
  dynamic "inbound_rule" {
    for_each = var.deploy_app_lb ? [var.app_lb_node_ports.http, var.app_lb_node_ports.https] : []
    content {
      action   = "accept"
      port     = inbound_rule.value
      ip_range = "${scaleway_lb_ip.app[0].ip_address}/32"
      protocol = "TCP"
    }
  }

  # Outbound — allow all for cluster nodes (nftables on bastion handles egress restriction)
  outbound_default_policy = "accept"

  project_id = var.project_id
  zone       = each.key
}
