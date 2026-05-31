# ==============================================================================
# Outscale — Bastion Host
# Private subnet + public IP for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

resource "outscale_security_group" "bastion" {
  description         = "OpenAether bastion — SSH from admin IPs only"
  security_group_name = "${var.cluster_name}-bastion-sg"
  net_id              = outscale_net.this.net_id
}

resource "outscale_security_group_rule" "bastion_ssh" {
  for_each          = toset(var.admin_ip)
  flow              = "Inbound"
  security_group_id = outscale_security_group.bastion.security_group_id
  from_port_range   = 22
  to_port_range     = 22
  ip_protocol       = "tcp"
  ip_range          = each.value
}

resource "outscale_public_ip" "bastion" {}

resource "outscale_vm" "bastion" {
  image_id           = coalesce(var.bastion_image_id, try(data.outscale_images.ubuntu.images[0].image_id, null))
  vm_type            = "tinav5.c2r4p1"
  subnet_id          = outscale_subnet.private.subnet_id
  security_group_ids = [outscale_security_group.bastion.security_group_id]

  user_data = base64encode(<<-EOT
    #cloud-config
    ssh_authorized_keys:
      - ${var.bastion_ssh_key}
    packages:
      - netcat-openbsd
      - tcpdump
  EOT
  )

  tags {
    key   = "Name"
    value = "${var.cluster_name}-bastion"
  }
}

resource "outscale_public_ip_link" "bastion" {
  vm_id     = outscale_vm.bastion.vm_id
  public_ip = outscale_public_ip.bastion.public_ip
}

data "outscale_images" "ubuntu" {
  filter {
    name   = "image_name"
    values = ["Ubuntu-22.04-LTS*"]
  }
}
