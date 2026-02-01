resource "scaleway_instance_security_group" "this" {
  name        = "${var.cluster_name}-sg"
  description = "Security Group for OpenAether Talos Cluster (Hardened)"

  # Inbound Rules - Principe du moindre privilège
  inbound_default_policy = "drop"

  # Kubernetes API - Depuis Load Balancer uniquement
  inbound_rule {
    action   = "accept"
    port     = 6443
    ip_range = "${scaleway_lb_ip.this.ip_address}/32"
    protocol = "TCP"
  }

  # Talos API - Depuis Bastion uniquement
  inbound_rule {
    action   = "accept"
    port     = 50000
    ip_range = "${scaleway_instance_ip.bastion.address}/32"
    protocol = "TCP"
  }

  # WireGuard - Communication inter-nœuds (réseau privé)
  # Note: Scaleway utilise un réseau privé par défaut
  inbound_rule {
    action   = "accept"
    port     = 51820
    ip_range = "10.0.0.0/8" # Réseau privé Scaleway
    protocol = "UDP"
  }

  # Outbound Rules
  outbound_default_policy = "accept"

  project_id = var.project_id
  zone       = var.zone
}
