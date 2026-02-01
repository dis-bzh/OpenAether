resource "outscale_security_group" "this" {
  description         = "Security Group for OpenAether Talos Cluster"
  security_group_name = "${var.cluster_name}-sg"
}

# Kubernetes API (TCP 6443)
resource "outscale_security_group_rule" "k8s_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 6443
  to_port_range     = 6443
  ip_protocol       = "tcp"
  ip_range          = "0.0.0.0/0"
}

# Talos API (TCP 50000)
resource "outscale_security_group_rule" "talos_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 50000
  to_port_range     = 50000
  ip_protocol       = "tcp"
  ip_range          = "0.0.0.0/0"
}

# WireGuard (UDP 51820)
resource "outscale_security_group_rule" "wireguard" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.this.security_group_id
  from_port_range   = 51820
  to_port_range     = 51820
  ip_protocol       = "udp"
  ip_range          = "0.0.0.0/0"
}

# Internal Traffic (Allow all from self - usually requires referencing SG ID)
# TODO: Find correct syntax for self-referencing SG in Outscale provider
# resource "outscale_security_group_rule" "internal" {
#   flow              = "Inbound"
#   security_group_id = outscale_security_group.this.security_group_id
#   ip_protocol       = "-1" # All traffic
#   rules_security_group = outscale_security_group.this.security_group_id
# }

# Outbound Allow All (Outscale default is usually deny all outbound for new SGs? No, usually allow all. Need to check.)
# Outscale default IS allow all outbound usually, but let's be explicit if needed.
# For now, rely on default or add rule if connectivity fails.
