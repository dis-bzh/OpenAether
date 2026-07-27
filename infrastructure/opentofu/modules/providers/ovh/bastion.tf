# ==============================================================================
# OVH / OpenStack — Bastion Host
# Private network only + floating IP for SSH admin access.
# Provides SSH jump to cluster nodes on port 50000 (Talos) and 6443 (K8s).
# ==============================================================================

data "openstack_images_image_v2" "bastion" {
  name        = var.bastion_image_id
  most_recent = true
  visibility  = "public"
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name                 = "${var.cluster_name}-bastion-sg"
  description          = "OpenAether bastion — SSH from admin IPs only"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each = toset(var.admin_ip)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

# Egress restricted to: established/related, DNS, NTP, apt, private subnet.
# nftables (in-VM) is the hard enforcement; this SG rule provides defence-in-depth
# by allowing egress to the private subnet and well-known services only.
resource "openstack_networking_secgroup_rule_v2" "bastion_egress_private" {
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "10.0.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_dns_tcp" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 53
  port_range_max    = 53
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_http" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress_https" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  security_group_id = openstack_networking_secgroup_v2.bastion.id
}

resource "openstack_networking_port_v2" "bastion" {
  name               = "${var.cluster_name}-bastion-port"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]

  # ⚠️ NE PAS retirer ce bloc. `network_id` seul ne crée AUCUNE dépendance vers
  # le subnet : OpenTofu peut créer le port avant lui, et Neutron le laisse
  # alors sans adresse IPv4. L'apply échoue plus loin, sur deux erreurs qui ne
  # désignent pas la cause :
  #   « Port <id> requires a FixedIP in order to be used »        (boot du bastion)
  #   « Cannot add floating IP to port <id> that has no fixed
  #     IPv4 addresses »                                          (association FIP)
  # Le bloc force l'ordre ET garantit l'allocation. C'est une course, donc un
  # échec INTERMITTENT : plusieurs déploiements OVH sont passés sans (constaté
  # le 2026-07-27). Les ports des control planes et le VIP le déclarent déjà.
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_compute_instance_v2" "bastion" {
  name        = "${var.cluster_name}-bastion"
  image_id    = data.openstack_images_image_v2.bastion.id
  flavor_name = var.bastion_flavor_name

  network {
    port = openstack_networking_port_v2.bastion.id
  }

  user_data = templatefile("${path.module}/../_shared/bastion-cloud-init.yaml.tftpl", {
    # ⚠️ PAS "ubuntu" : c'est l'utilisateur par défaut de l'image OVH, donc
    # déjà créé par `users: [default]`. cloud-init ignore alors la seconde
    # définition et l'utilisateur n'est JAMAIS ajouté au groupe
    # bastion-admins → sshd le refuse via AllowGroups (constaté en réel :
    # "Permission denied (publickey)" avec la bonne clé). Un nom dédié,
    # comme sur Scaleway, évite la collision.
    bastion_user      = "bastion"
    ssh_keys          = var.bastion_ssh_keys
    private_cidr      = "10.0.0.0/24"
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
  })

  tags = ["bastion", var.cluster_name]
}

resource "openstack_networking_floatingip_v2" "bastion" {
  pool = var.network_name
}

resource "openstack_networking_floatingip_associate_v2" "bastion" {
  floating_ip = openstack_networking_floatingip_v2.bastion.address
  port_id     = openstack_networking_port_v2.bastion.id
}
