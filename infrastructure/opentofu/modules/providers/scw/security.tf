resource "scaleway_instance_security_group" "this" {
  for_each    = toset(var.additional_zones)
  name        = "${var.cluster_name}-sg-${each.key}"
  description = "Security Group for OpenAether Talos Cluster in ${each.key} (Hardened)"

  # Inbound Rules - Principe du moindre privilège
  inbound_default_policy = "drop"

  # Kubernetes API - Depuis App LB
  inbound_rule {
    action   = "accept"
    port     = 6443
    ip_range = "${scaleway_lb_ip.app.ip_address}/32"
    protocol = "TCP"
  }

  # Kubernetes API - Depuis Admin LB (quand actif)
  dynamic "inbound_rule" {
    for_each = var.admin_lb_enabled ? [1] : []
    content {
      action   = "accept"
      port     = 6443
      ip_range = "${scaleway_lb_ip.admin[0].ip_address}/32"
      protocol = "TCP"
    }
  }

  # Talos API - Depuis Admin LB (quand actif)
  dynamic "inbound_rule" {
    for_each = var.admin_lb_enabled ? [1] : []
    content {
      action   = "accept"
      port     = 50000
      ip_range = "${scaleway_lb_ip.admin[0].ip_address}/32"
      protocol = "TCP"
    }
  }

  # Talos API - Depuis Bastion
  inbound_rule {
    action   = "accept"
    port     = 50000
    ip_range = "${scaleway_instance_ip.bastion.address}/32"
    protocol = "TCP"
  }

  # Communication inter-nœuds (réseau privé) et Health Checks LB
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
    ip_range = "100.64.0.0/10" # Scaleway internal/LB health checks
    protocol = "ANY"
  }

  # HTTP/HTTPS - Depuis App LB
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

  # Outbound Rules
  outbound_default_policy = "accept"

  project_id = var.project_id
  zone       = each.key
}

