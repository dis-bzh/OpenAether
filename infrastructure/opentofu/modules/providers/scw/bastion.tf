resource "scaleway_instance_ip" "bastion" {
  zone = var.zone
}

resource "scaleway_instance_security_group" "bastion" {
  name                    = "${var.cluster_name}-bastion-sg"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.admin_ip
  }
}

resource "scaleway_instance_server" "bastion" {
  name       = "${var.cluster_name}-bastion"
  type       = "DEV1-S" # Instance minimale pour réduire les coûts
  image      = var.bastion_image_id
  zone       = var.zone
  project_id = var.project_id
  ip_id      = scaleway_instance_ip.bastion.id

  security_group_id = scaleway_instance_security_group.bastion.id

  # User data for cloud-init to configure SSH
  user_data = {
    "cloud-init" = <<-EOT
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
        - |
          # Fix asymmetric routing: ensure private network DHCP doesn't override public default gateway
          PRIVATE_IF=$(ip -4 addr show | grep 172.16 | awk '{print $NF}')
          if [ -n "$PRIVATE_IF" ]; then
            echo "network: {version: 2, ethernets: {$PRIVATE_IF: {dhcp4: true, dhcp4-overrides: {use-routes: false}}}}" > /etc/netplan/99-vpc-ignore-default.yaml
            netplan apply
          fi
    EOT
  }

  tags = ["bastion", var.cluster_name]
}
