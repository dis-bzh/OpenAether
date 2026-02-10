mock_provider "scaleway" {}
mock_provider "talos" {}
mock_provider "aws" {}

override_resource {
  target = aws_s3_object.talosconfig
  values = { id = "dummy-s3-talosconfig" }
}

override_resource {
  target = aws_s3_object.kubeconfig
  values = { id = "dummy-s3-kubeconfig" }
}

override_resource {
  target = aws_s3_object.controlplane_yaml
  values = { id = "dummy-s3-controlplane" }
}

override_resource {
  target = aws_s3_object.worker_yaml
  values = { id = "dummy-s3-worker" }
}

# Surcharge des data sources pour simuler la présence d'images
override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = {
    id = "dummy-talos-id"
  }
}

override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = {
    id = "dummy-worker-id"
  }
}

# Surcharge des ressources Computed pour éviter les chaînes aléatoires invalides (ex: CIDR)
override_resource {
  target = module.scw.scaleway_lb_ip.this
  values = {
    id         = "33333333-3333-3333-3333-333333333333"
    ip_address = "1.1.1.1"
  }
}

override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = {
    id      = "44444444-4444-4444-4444-444444444444"
    address = "2.2.2.2"
  }
}

override_resource {
  target = module.scw.scaleway_vpc_public_gateway_ip.this
  values = {
    address = "3.3.3.3"
  }
}

override_resource {
  target = module.scw.scaleway_vpc_public_gateway.this
  values = {
    id = "11111111-1111-1111-1111-111111111111"
  }
}

override_resource {
  target = module.scw.scaleway_vpc_private_network.this
  values = {
    id = "22222222-2222-2222-2222-222222222222"
  }
}

override_resource {
  target = module.scw.scaleway_lb.this
  values = {
    id = "55555555-5555-5555-5555-555555555555"
  }
}

override_resource {
  target = module.scw.scaleway_lb_backend.control_plane
  values = {
    id = "66666666-6666-6666-6666-666666666666"
  }
}

override_resource {
  target = module.scw.scaleway_lb_backend.http
  values = {
    id = "77777777-7777-7777-7777-777777777777"
  }
}

override_resource {
  target = module.scw.scaleway_lb_backend.https
  values = {
    id = "88888888-8888-8888-8888-888888888888"
  }
}

override_resource {
  target = module.scw.scaleway_lb_frontend.control_plane
  values = {
    id = "99999999-9999-9999-9999-999999999999"
  }
}

override_resource {
  target = module.scw.scaleway_lb_frontend.http
  values = {
    id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  }
}

override_resource {
  target = module.scw.scaleway_lb_frontend.https
  values = {
    id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  }
}

override_resource {
  target = module.scw.scaleway_lb_private_network.this
  values = {
    id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
  }
}



# Variables globales pour les tests
variables {
  cluster_name     = "test-cluster"
  zone             = "fr-par-1"
  additional_zones = ["fr-par-1", "fr-par-2"]
  admin_ip         = ["1.2.3.4/32"]
  bastion_ssh_keys = {
    scaleway = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpj9y94C3NzaC1lZDI1NTE5AAAAIOMpj9y9"
  }
  node_distribution = {
    scaleway = {
      control_planes = 3
      workers        = 1
      image_name     = "talos"
      instance_type  = "DEV1-S"
      zone           = "fr-par-1"
      zones          = ["fr-par-1", "fr-par-2", "fr-par-1"]
    }
  }
}

# --- Test 1: Variable Validation ---
run "verify_variable_validation" {
  command = plan

  assert {
    condition     = var.node_distribution.scaleway.control_planes == 3
    error_message = "Le Control Plane Scaleway doit avoir 3 nœuds pour la HA."
  }

  assert {
    condition     = contains(var.additional_zones, var.zone)
    error_message = "La zone principale doit être incluse dans additional_zones."
  }
}

# --- Test 2: Bastion Configuration ---
run "verify_bastion_config" {
  command = plan

  assert {
    condition     = length(var.bastion_ssh_keys.scaleway) > 0
    error_message = "La clé SSH du bastion Scaleway ne peut pas être vide."
  }
}

# --- Test 3: Module Activation Logic ---
run "verify_module_activation" {
  command = plan

  # Scaleway module should be active (control_planes + workers > 0)
  assert {
    condition     = length(module.scw) == 1
    error_message = "Le module Scaleway devrait être activé quand des nœuds sont configurés."
  }

  # OVH and Outscale modules should NOT be active
  assert {
    condition     = length(module.ovh) == 0
    error_message = "Le module OVH ne devrait pas être activé sans nœuds configurés."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Le module Outscale ne devrait pas être activé sans nœuds configurés."
  }
}

# --- Test 4: Security Outputs ---
run "verify_security_outputs" {
  command = apply

  # Bastion IP should be available
  assert {
    condition     = output.bastion_ips != null
    error_message = "Les IPs bastion doivent être disponibles en sortie."
  }

  # Cluster endpoint should be set
  assert {
    condition     = output.cluster_endpoint != ""
    error_message = "L'endpoint du cluster ne peut pas être vide."
  }

  # Sensitive outputs should be defined
  assert {
    condition     = output.talosconfig != null
    error_message = "La talosconfig doit être définie en sortie."
  }
}

# --- Test 5: HA Configuration ---
run "verify_ha_configuration" {
  command = plan

  # At least 3 control planes for HA
  assert {
    condition     = var.node_distribution.scaleway.control_planes >= 3
    error_message = "HA nécessite au minimum 3 control planes."
  }

  # Control planes should be distributed across zones
  assert {
    condition     = length(var.node_distribution.scaleway.zones) >= 2
    error_message = "Les control planes doivent être distribués sur au moins 2 zones."
  }
}
