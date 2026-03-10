data "outscale_images" "ubuntu" {
  filter {
    name   = "image_name"
    values = ["Ubuntu-22.04-LTS*"]
  }
}

resource "outscale_security_group" "bastion" {
  description         = "Security Group for Bastion Host"
  security_group_name = "${var.cluster_name}-bastion-sg"
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

resource "outscale_public_ip" "bastion" {
}

resource "outscale_vm" "bastion" {
  image_id = coalesce(var.bastion_image_id, try(data.outscale_images.ubuntu.images[0].image_id, "ami-12345678")) # Try finding, fallback if empty
  vm_type  = "tinav5.c2r4p1"

  security_group_ids = [outscale_security_group.bastion.security_group_id]

  user_data = base64encode(<<-EOT
    #cloud-config
    ssh_authorized_keys:
      - ${var.bastion_ssh_key}

    packages:
      - curl
      - wget
      - netcat
      - tcpdump

    runcmd:
      - echo "Bastion initialized" > /etc/motd
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
