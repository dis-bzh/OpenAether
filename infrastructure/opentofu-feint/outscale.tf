# Outscale fixture — the shapes modules/providers/outscale builds, minus what the
# emulator does not serve (security groups, public IPs, internet service, NAT,
# route tables, load balancers). This is the FIRST apply-mode coverage Outscale
# has in this repository: cluster/tests/*.tftest.hcl mocks it at plan level only.

resource "outscale_net" "this" {
  count    = local.outscale_active
  ip_range = "10.0.0.0/16"

  # The provider calls CreateTags on almost everything, and tag order is a
  # permanent diff waiting to happen.
  tags {
    key   = "name"
    value = var.cluster_name
  }
}

resource "outscale_subnet" "private" {
  count          = local.outscale_active
  net_id         = outscale_net.this[0].net_id
  ip_range       = "10.0.0.0/24"
  subregion_name = "eu-west-2a"

  tags {
    key   = "name"
    value = "${var.cluster_name}-private"
  }
}

resource "outscale_subnet" "public" {
  count          = local.outscale_active
  net_id         = outscale_net.this[0].net_id
  ip_range       = "10.0.1.0/24"
  subregion_name = "eu-west-2a"

  tags {
    key   = "name"
    value = "${var.cluster_name}-public"
  }
}

# Addressed by name at create and by id at destroy — both must be the same
# identity, which is only visible on a real destroy.
resource "outscale_keypair" "bastion" {
  count        = local.outscale_active
  keypair_name = "${var.cluster_name}-bastion"
  public_key   = local.bastion_ssh_keys[0]
}

resource "outscale_volume" "worker_data" {
  count          = local.outscale_active
  subregion_name = "eu-west-2a"
  size           = 10
}

resource "outscale_vm" "control_plane" {
  count     = local.outscale_active
  image_id  = "ami-00000001"
  vm_type   = "tinav6.c1r1p2"
  subnet_id = outscale_subnet.private[0].subnet_id

  tags {
    key   = "name"
    value = "${var.cluster_name}-cp-0"
  }
}

resource "outscale_vm" "worker" {
  count     = local.outscale_active
  image_id  = "ami-00000001"
  vm_type   = "tinav6.c1r1p2"
  subnet_id = outscale_subnet.private[0].subnet_id

  tags {
    key   = "name"
    value = "${var.cluster_name}-worker-0"
  }
}

# outscale_volume_link is deliberately absent, and it is the one production
# resource this fixture cannot carry: the provider waits for the link by calling
# ReadVolumes with a LinkVolumeVmIds filter, which the emulator refuses with
# "the filter(s) LinkVolumeVmIds are not emulated" — by design, since it applies
# a filter or rejects it rather than silently returning everything. Attaching a
# worker data disk on Outscale therefore stays unexercised here.

# The bastion user is deliberately not the image default: cloud-init ignores a
# second definition of an existing user, so the account never joins
# bastion-admins and sshd rejects it through AllowGroups.
resource "outscale_vm" "bastion" {
  count        = local.outscale_active
  image_id     = "ami-00000001"
  vm_type      = "tinav6.c1r1p2"
  subnet_id    = outscale_subnet.public[0].subnet_id
  keypair_name = outscale_keypair.bastion[0].keypair_name
  user_data    = base64encode(local.bastion_cloud_init)

  tags {
    key   = "name"
    value = "${var.cluster_name}-bastion"
  }
}
