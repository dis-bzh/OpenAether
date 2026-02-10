# Mocking des providers OpenStack pour OVH
mock_provider "openstack" {}

# Surcharge des ressources pour éviter les erreurs de validation
override_resource {
  target = module.ovh.openstack_networking_floatingip_v2.vip
  values = {
    address = "123.123.123.123"
  }
}

override_data {
  target = module.ovh.data.openstack_images_image_v2.bastion
  values = {
    id = "dummy-bastion-image-id"
  }
}

override_resource {
  target = module.ovh.openstack_networking_port_v2.control_plane
  values = {
    id = "ovh-port-id"
    all_fixed_ips = ["192.168.1.10"]
  }
}

override_resource {
  target = module.ovh.openstack_compute_instance_v2.control_plane
  values = {
    access_ip_v4 = "192.168.1.10"
  }
}

override_resource {
  target = module.ovh.openstack_compute_instance_v2.worker
  values = {
    access_ip_v4 = "192.168.1.11"
  }
}

# Variables globales pour les tests OVH
variables {
  cluster_name      = "test-ovh"
  admin_ip          = ["1.2.3.4/32"]
  bastion_ssh_keys  = {
    ovh = "ssh-ed25519 AAAAC3... dummy"
  }
  node_distribution = {
    ovh = {
      control_planes = 3
      workers        = 2
      region         = "GRA11"
      instance_type  = "b2-7"
      image_id       = "dummy-ovh-image-id"
    }
  }
}

# --- Test 1: Configuration Validation ---
run "verify_ovh_ha_config" {
  command = plan

  assert {
    condition     = var.node_distribution.ovh.control_planes == 3
    error_message = "OVH Control Plane doit avoir 3 nœuds pour la HA."
  }

  assert {
    condition     = var.node_distribution.ovh.region == "GRA11"
    error_message = "La région OVH par défaut pour les tests doit être GRA11."
  }
}

# --- Test 2: Module Activation ---
run "verify_ovh_module_activation" {
  command = plan

  # OVH module should be active
  assert {
    condition     = length(module.ovh) == 1
    error_message = "Le module OVH devrait être activé quand des nœuds sont configurés."
  }

  # Scaleway and Outscale should NOT be active
  assert {
    condition     = length(module.scw) == 0
    error_message = "Le module Scaleway ne devrait pas être activé sans nœuds configurés."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Le module Outscale ne devrait pas être activé sans nœuds configurés."
  }
}

# --- Test 3: Security Outputs ---
run "verify_ovh_outputs" {
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
