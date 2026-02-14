# Private Network for secure internal communication
resource "scaleway_vpc_private_network" "this" {
  name   = "${var.cluster_name}-private-network"
  region = var.region
}

# Reserve IPs for control plane nodes via IPAM (VPC v2)
resource "scaleway_ipam_ip" "control_plane" {
  count      = var.control_plane_count
  project_id = var.project_id
  region     = var.region

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

# Attach control plane nodes to private network with reserved IPAM IPs
resource "scaleway_instance_private_nic" "control_plane" {
  count = var.control_plane_count

  server_id          = scaleway_instance_server.control_plane[count.index].id
  private_network_id = scaleway_vpc_private_network.this.id
  ipam_ip_ids        = [scaleway_ipam_ip.control_plane[count.index].id]
  zone               = element(var.additional_zones, count.index)
}

# Attach worker nodes to private network
resource "scaleway_instance_private_nic" "worker" {
  count = var.worker_count

  server_id          = scaleway_instance_server.worker[count.index].id
  private_network_id = scaleway_vpc_private_network.this.id
  zone               = var.zone
}

# Attach bastion to private network (for access to nodes)
resource "scaleway_instance_private_nic" "bastion" {
  server_id          = scaleway_instance_server.bastion.id
  private_network_id = scaleway_vpc_private_network.this.id
  zone               = var.zone
}

# --- NAT & Internet Access for Private Nodes (VPC v2) ---

# IP for the Public Gateway
resource "scaleway_vpc_public_gateway_ip" "this" {
  project_id = var.project_id
  zone       = var.zone
}

# Public Gateway (NAT)
resource "scaleway_vpc_public_gateway" "this" {
  name       = "${var.cluster_name}-gateway"
  type       = "VPC-GW-S"
  project_id = var.project_id
  zone       = var.zone
  ip_id      = scaleway_vpc_public_gateway_ip.this.id

  # Ensure IP is fully created before the gateway
  depends_on = [scaleway_vpc_public_gateway_ip.this]
}

# Bridge Private Network and Public Gateway using IPAM (VPC v2)
resource "scaleway_vpc_gateway_network" "main" {
  gateway_id         = scaleway_vpc_public_gateway.this.id
  private_network_id = scaleway_vpc_private_network.this.id
  enable_masquerade  = true # Enable NAT
  zone               = var.zone

  ipam_config {
    push_default_route = true  # Push default route to nodes for Internet access via NAT
  }
}
