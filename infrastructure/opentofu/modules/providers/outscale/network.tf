# ==============================================================================
# Outscale — Network (AWS-style two-subnet layout for node egress)
#
#   private subnet (10.0.0.0/24) — cluster control planes + workers.
#     Default route -> NAT service, so the nodes (which have NO public IP) still
#     reach the internet for image pulls and NTP.
#   public  subnet (10.0.1.0/24) — bastion, NAT service, internet-facing LBs.
#     Default route -> Internet Gateway.
#
# A bare Internet Gateway only NATs instances that own a public IP (1:1), so a
# private subnet needs a NAT Service for outbound. This mirrors the egress paths
# the other providers already have (Scaleway public-gateway, OVH router SNAT).
# ==============================================================================

resource "outscale_net" "this" {
  ip_range = "10.0.0.0/16"

  tags {
    key   = "Name"
    value = "${var.cluster_name}-net"
  }
}

# --- Private subnet: cluster nodes (egress via the NAT service) ---
resource "outscale_subnet" "private" {
  net_id         = outscale_net.this.net_id
  ip_range       = "10.0.0.0/24"
  subregion_name = var.availability_zones[0]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-subnet"
  }
}

# --- Public subnet: bastion, NAT service, internet-facing LBs (egress via IGW) ---
resource "outscale_subnet" "public" {
  net_id         = outscale_net.this.net_id
  ip_range       = "10.0.1.0/24"
  subregion_name = var.availability_zones[0]

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-subnet"
  }
}

# --- Internet Gateway (outbound for the public subnet + NAT service) ---
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

# --- NAT service: gives the private nodes outbound internet (no public IP needed) ---
resource "outscale_public_ip" "nat" {}

resource "outscale_nat_service" "this" {
  subnet_id    = outscale_subnet.public.subnet_id
  public_ip_id = outscale_public_ip.nat.public_ip_id

  # The NAT service must sit behind a working IGW route before it can forward.
  depends_on = [outscale_internet_service_link.this, outscale_route_table_link.public]
}

# --- Public route table: 0.0.0.0/0 -> Internet Gateway ---
resource "outscale_route_table" "public" {
  net_id = outscale_net.this.net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-public-rt"
  }
}

resource "outscale_route" "public_internet" {
  route_table_id       = outscale_route_table.public.route_table_id
  destination_ip_range = "0.0.0.0/0"
  gateway_id           = outscale_internet_service.this.internet_service_id
}

resource "outscale_route_table_link" "public" {
  route_table_id = outscale_route_table.public.route_table_id
  subnet_id      = outscale_subnet.public.subnet_id
}

# --- Private route table: 0.0.0.0/0 -> NAT service ---
resource "outscale_route_table" "private" {
  net_id = outscale_net.this.net_id

  tags {
    key   = "Name"
    value = "${var.cluster_name}-private-rt"
  }
}

resource "outscale_route" "private_nat" {
  route_table_id       = outscale_route_table.private.route_table_id
  destination_ip_range = "0.0.0.0/0"
  nat_service_id       = outscale_nat_service.this.nat_service_id
}

resource "outscale_route_table_link" "private" {
  route_table_id = outscale_route_table.private.route_table_id
  subnet_id      = outscale_subnet.private.subnet_id
}
