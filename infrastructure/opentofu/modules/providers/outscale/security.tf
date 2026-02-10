resource "outscale_security_group" "this" {
  description         = "Security Group for OpenAether Talos Cluster"
  security_group_name = "${var.cluster_name}-sg"
}

# Kubernetes API (TCP 6443) - Restricted to Admin IPs only
resource "outscale_security_group_rule" "k8s_api" {
  for_each          = toset(var.admin_ip)
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = each.value
}

# Talos API (TCP 50000) - Restricted to Bastion SG
resource "outscale_security_group_rule" "talos_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    from_port_range = 50000
    to_port_range   = 50000
    ip_protocol     = "tcp"
    security_groups_members {
      security_group_id = outscale_security_group.bastion.security_group_id
    }
  }
}

# HTTP/HTTPS - Open for ingress traffic
resource "outscale_security_group_rule" "http" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 80
  to_port_range     = 80
  ip_protocol       = "tcp"
  ip_range          = "0.0.0.0/0"
}

resource "outscale_security_group_rule" "https" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 443
  to_port_range     = 443
  ip_protocol       = "tcp"
  ip_range          = "0.0.0.0/0"
}

# WireGuard / Cilium (UDP 51820) - Restricted to cluster SG (inter-node only)
resource "outscale_security_group_rule" "wireguard" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    from_port_range = 51820
    to_port_range   = 51820
    ip_protocol     = "udp"
    security_groups_members {
      security_group_id = outscale_security_group.this.security_group_id
    }
  }
}

# Internal Traffic - Allow all from cluster SG members (self-referencing)
resource "outscale_security_group_rule" "internal" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    ip_protocol = "-1"
    security_groups_members {
      security_group_id = outscale_security_group.this.security_group_id
    }
  }
}
