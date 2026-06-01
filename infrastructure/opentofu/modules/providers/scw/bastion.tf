resource "scaleway_instance_ip" "bastion" {
  zone = var.zone
}

resource "scaleway_instance_security_group" "bastion" {
  name                    = "${var.cluster_name}-bastion-sg"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = var.admin_ip
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }
}

resource "scaleway_instance_server" "bastion" {
  name       = "${var.cluster_name}-bastion"
  type       = "DEV1-S"
  image      = var.bastion_image_id
  zone       = var.zone
  project_id = var.project_id
  ip_id      = scaleway_instance_ip.bastion.id

  security_group_id = scaleway_instance_security_group.bastion.id

  user_data = {
    "cloud-init" = <<-EOT
      #cloud-config
      # Dedicated unprivileged user for the SSH tunnels (no root login, no
      # password). It only relays TCP to the nodes' Talos API; the routing fix
      # below runs as a root systemd service, independent of this user.
      users:
        - default
        - name: bastion
          shell: /bin/bash
          ssh_authorized_keys:
            - ${var.bastion_ssh_key}
      ssh_pwauth: false
      disable_root: true
      write_files:
        - path: /etc/ssh/sshd_config.d/99-bastion-hardening.conf
          content: |
            # Scaleway re-injects the SSH key into root via its platform, so
            # disable_root (cloud-init) isn't enough — block root at the sshd level.
            PermitRootLogin no
            PasswordAuthentication no
        - path: /usr/local/sbin/fix-priv-route.sh
          permissions: '0755'
          content: |
            #!/bin/bash
            # The VPC public gateway pushes a default route to every instance on the
            # private network (NAT for the nodes). On this bastion (which also has a
            # public IP) that route hijacks return traffic and breaks inbound SSH
            # (asymmetric routing). The private NIC attaches ~30s after boot, so wait
            # for it, then make it ignore DHCP routes — keeping the public default.
            IF=""
            for i in $(seq 1 60); do
              IF=$(ip -o -4 addr show | awk '$4 ~ /^172\.16\./ {print $2; exit}')
              [ -n "$IF" ] && break
              sleep 5
            done
            [ -n "$IF" ] || exit 0
            printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      dhcp4: true\n      dhcp4-overrides:\n        use-routes: false\n' "$IF" > /etc/netplan/99-no-priv-route.yaml
            chmod 600 /etc/netplan/99-no-priv-route.yaml
            netplan apply
            sleep 3
            ip route show default | awk '$3 ~ /^172\.16\./ {print}' | while read -r R; do ip route del $R || true; done
        - path: /etc/systemd/system/fix-priv-route.service
          content: |
            [Unit]
            Description=Keep the public default route on the bastion (drop VPC-pushed private default)
            After=network.target
            [Service]
            Type=oneshot
            ExecStart=/usr/local/sbin/fix-priv-route.sh
            [Install]
            WantedBy=multi-user.target
      runcmd:
        - systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        - systemctl daemon-reload
        - systemctl enable --now fix-priv-route.service
    EOT
  }

  tags = ["bastion", var.cluster_name]
}
