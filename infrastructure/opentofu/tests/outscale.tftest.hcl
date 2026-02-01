# Mocking du provider Outscale
mock_provider "outscale" {}

# Surcharge des ressources Computed
override_resource {
  target = module.outscale.outscale_load_balancer.this
  values = {
    dns_name = "test-lb.outscale.com"
  }
}

override_data {
  target = module.outscale.data.outscale_images.ubuntu
  values = {
    images = [{
      image_id = "dummy-bastion-image-id"
      account_alias = "dummy"
      account_id = "dummy"
      architecture = "x86_64"
      block_device_mappings = []
      boot_modes = []
      creation_date = "2024-01-01T00:00:00Z"
      description = "dummy"
      file_location = "dummy"
      image_name = "dummy-ubuntu"
      image_type = "machine"
      permissions_to_launch = []
      product_codes = []
      root_device_name = "/dev/sda1"
      root_device_type = "ebs"
      secure_boot = false
      state = "available"
      state_comment = []
      tags = []
    }]
  }
}

override_resource {
  target = module.outscale.outscale_nic.control_plane
  values = {
    nic_id    = "test-nic-id"
  }
}

override_resource {
  target = module.outscale.outscale_vm.control_plane
  values = {
    vm_id = "test-vm-id"
    private_ip = "10.0.1.10"
  }
}

override_resource {
  target = module.outscale.outscale_vm.worker
  values = {
    vm_id      = "worker-vm-id"
    private_ip = "10.0.1.11"
  }
}

# Variables globales pour les tests Outscale
variables {
  cluster_name      = "test-osc"
  admin_ip          = ["1.2.3.4/32"]
  bastion_ssh_keys  = {
    outscale = "ssh-ed25519 AAAAC3... dummy"
  }
  node_distribution = {
    outscale = {
      control_planes = 3
      workers        = 1
      region         = "eu-west-2"
      instance_type  = "tinav5.c2r4p1"
      image_id       = "ami-ce7e9d99"
      subnet_id      = "subnet-12345678"
    }
  }
}

run "verify_outscale_config" {
  command = plan

  assert {
    condition     = var.node_distribution.outscale.control_planes == 3
    error_message = "Outscale Control Plane doit avoir 3 nœuds."
  }

  assert {
    condition     = var.node_distribution.outscale.region == "eu-west-2"
    error_message = "La région Outscale par défaut pour les tests doit être eu-west-2."
  }
}
