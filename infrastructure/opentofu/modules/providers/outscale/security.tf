# ==============================================================================
# Outscale — Security Groups
# inbound_default = drop. Only required ports explicitly opened.
# ==============================================================================

resource "outscale_security_group" "this" {
  description         = "OpenAether cluster nodes — least-privilege inbound"
  security_group_name = "${var.cluster_name}-cluster-sg"
  net_id              = outscale_net.this.net_id
}

# Kubernetes API — from LB subnet (health checks) + admin IPs
resource "outscale_security_group_rule" "k8s_api_private" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = "10.0.0.0/24"
}

resource "outscale_security_group_rule" "k8s_api_admin" {
  for_each          = toset(var.admin_ip)
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = each.value
}

# Talos API — from bastion security group only
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

# HTTP/HTTPS — from LB subnet
resource "outscale_security_group_rule" "http" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 80
  to_port_range     = 80
  ip_protocol       = "tcp"
  ip_range          = "10.0.0.0/24"
}

resource "outscale_security_group_rule" "https" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 443
  to_port_range     = 443
  ip_protocol       = "tcp"
  ip_range          = "10.0.0.0/24"
}

# WireGuard — Cilium inter-node encryption (UDP 51820)
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

# Inter-node — full mesh (etcd, kubelet, Cilium)
resource "outscale_security_group_rule" "inter_node" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id

  rules {
    ip_protocol = "-1"
    security_groups_members {
      security_group_id = outscale_security_group.this.security_group_id
    }
  }
}
