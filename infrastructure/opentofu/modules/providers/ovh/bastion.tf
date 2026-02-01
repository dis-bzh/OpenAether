data "openstack_images_image_v2" "bastion" {
  name        = var.bastion_image_id
  most_recent = true
  visibility  = "public"
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security Group for Bastion Host"
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each          = toset(var.admin_ip)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_compute_instance_v2" "bastion" {
  name        = "${var.cluster_name}-bastion"
  image_id    = data.openstack_images_image_v2.bastion.id
  flavor_name = "b2-7" # Standard implementation, adjust if needed
  
  # Connect to Public Network (Ext-Net)
  network {
    name = var.network_name
  }

  # Connect to Private Network
  network {
    uuid = var.network_id
  }

  security_groups = [openstack_networking_secgroup_v2.bastion.name]

  user_data = <<-EOT
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
      # Enable forwarding if needed, but primary use is SSH jump
  EOT
}
