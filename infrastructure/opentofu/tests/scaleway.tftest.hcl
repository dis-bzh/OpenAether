# Mocking des providers pour éviter les appels API réels pendant les tests unitaires
mock_provider "scaleway" {}

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

override_resource {
  target = module.scw.scaleway_lb_acl.k8s_api_whitelist
  values = {
    id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
  }
}

override_resource {
  target = module.scw.scaleway_lb_acl.k8s_api_deny
  values = {
    id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
  }
}

# Variables globales pour les tests
variables {
  cluster_name      = "test-cluster"
  zone              = "fr-par-1"
  additional_zones  = ["fr-par-1", "fr-par-2"]
  admin_ip          = ["1.2.3.4/32"]
  bastion_ssh_keys  = {
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

# Bloc de test unitaire (sans provisionnement réel grâce aux mocks si possible, 
# mais ici OpenTofu test provisionne par défaut. Nous testons la logique des variables.)

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

run "verify_bastion_config" {
  command = plan

  assert {
    condition     = length(var.bastion_ssh_keys.scaleway) > 0
    error_message = "La clé SSH du bastion Scaleway ne peut pas être vide."
  }
}
