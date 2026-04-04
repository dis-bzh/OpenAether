# Security Groups — Least-privilege inbound, permissive outbound
#
# Network access strategy:
#   - 6443/TCP: Kubernetes API via K8s LB (permanent)
#   - 50000/TCP: Talos API via bastion ONLY. Accessible via SSH tunnels established
#                through the bastion host. Never exposed via Load Balancers.
#   - 80/443:   App traffic via App LB
#   - Inter-node: full mesh on private subnets
# ==============================================================================

resource "scaleway_instance_security_group" "this" {
  for_each    = toset(var.additional_zones)
  name        = "${var.cluster_name}-sg-${each.key}"
  description = "Security Group for OpenAether Talos Cluster in ${each.key}"

  inbound_default_policy = "drop"

  # Kubernetes API — From K8s LB
  inbound_rule {
    action   = "accept"
    port     = 6443
    ip_range = "${scaleway_lb_ip.k8s.ip_address}/32"
    protocol = "TCP"
  }

  # Kubernetes API — From App LB (for internal service communication)
  inbound_rule {
    action   = "accept"
    port     = 6443
    ip_range = "${scaleway_lb_ip.app.ip_address}/32"
    protocol = "TCP"
  }

  # Talos API — From Bastion ONLY (50000/TCP, never from LB)
  inbound_rule {
    action   = "accept"
    port     = 50000
    ip_range = "${scaleway_instance_ip.bastion.address}/32"
    protocol = "TCP"
  }

  # Inter-node communication (private subnets) + LB health checks
  inbound_rule {
    action   = "accept"
    port     = 0
    ip_range = "172.16.0.0/12"
    protocol = "ANY"
  }

  inbound_rule {
    action   = "accept"
    port     = 0
    ip_range = "10.0.0.0/8"
    protocol = "ANY"
  }

  inbound_rule {
    action   = "accept"
    port     = 0
    ip_range = "100.64.0.0/10" # Scaleway internal / LB health checks
    protocol = "ANY"
  }

  # HTTP/HTTPS — From App LB
  inbound_rule {
    action   = "accept"
    port     = 80
    ip_range = "${scaleway_lb_ip.app.ip_address}/32"
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = 443
    ip_range = "${scaleway_lb_ip.app.ip_address}/32"
    protocol = "TCP"
  }

  # Outbound — Allow all
  outbound_default_policy = "accept"

  project_id = var.project_id
  zone       = each.key
}
