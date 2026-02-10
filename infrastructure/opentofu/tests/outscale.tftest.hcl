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

# --- Test 1: Configuration Validation ---
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

# --- Test 2: Module Activation ---
run "verify_outscale_module_activation" {
  command = plan

  # Outscale module should be active
  assert {
    condition     = length(module.outscale) == 1
    error_message = "Le module Outscale devrait être activé quand des nœuds sont configurés."
  }

  # Scaleway and OVH should NOT be active
  assert {
    condition     = length(module.scw) == 0
    error_message = "Le module Scaleway ne devrait pas être activé sans nœuds configurés."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "Le module OVH ne devrait pas être activé sans nœuds configurés."
  }
}

# --- Test 3: Security Outputs ---
run "verify_outscale_outputs" {
  command = plan

  assert {
    condition     = output.bastion_ips != null
    error_message = "Les IPs bastion doivent être disponibles en sortie."
  }

  assert {
    condition     = output.cluster_endpoint != ""
    error_message = "L'endpoint du cluster ne peut pas être vide."
  }
}

# --- Test 4: HA Requirements ---
run "verify_outscale_ha" {
  command = plan

  assert {
    condition     = var.node_distribution.outscale.control_planes >= 3
    error_message = "HA nécessite au minimum 3 control planes Outscale."
  }
}
