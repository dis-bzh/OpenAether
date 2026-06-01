# ==============================================================================
# Outscale — Network (Net + Subnet + Internet Gateway)
# Private subnet for cluster nodes. Internet Gateway for outbound.
# Bastion has a public IP for admin access.
# ==============================================================================

resource "outscale_net" "this" {
  ip_range = "10.0.0.0/16"

  tags {
    key   = "Name"
    value = "${var.cluster_name}-net"
  }
}

resource "outscale_subnet" "private" {
  net_id         = outscale_net.this.net_id
  ip_range       = "10.0.0.0/24"
  subregion_name = var.availability_zones[0]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-subnet"
  }
}

# Internet Gateway for outbound connectivity (image pulls, updates)
resource "outscale_internet_service" "this" {
  tags {
    key   = "Name"
    value = "${var.cluster_name}-igw"
  }
}

resource "outscale_internet_service_link" "this" {
  internet_service_id = outscale_internet_service.this.internet_service_id
  net_id              = outscale_net.this.net_id
}

resource "outscale_route_table" "private" {
  net_id = outscale_net.this.net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-rt"
  }
}

resource "outscale_route" "internet" {
  route_table_id       = outscale_route_table.private.route_table_id
  destination_ip_range = "0.0.0.0/0"
  gateway_id           = outscale_internet_service.this.internet_service_id
}

resource "outscale_route_table_link" "private" {
  route_table_id = outscale_route_table.private.route_table_id
  subnet_id      = outscale_subnet.private.subnet_id
}
