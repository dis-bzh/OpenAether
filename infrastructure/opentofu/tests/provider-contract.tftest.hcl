# ==============================================================================
# Provider Contract Tests
# Validates cross-provider behaviors, the single-provider constraint,
# and edge cases in the junction point logic.
# ==============================================================================

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "talos" {}
mock_provider "aws" {
  mock_resource "aws_s3_object" {
    defaults = { id = "mock-id" }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

override_resource {
  target = aws_s3_object.talosconfig
  values = { id = "s3-talosconfig" }
}
override_resource {
  target = aws_s3_object.kubeconfig
  values = { id = "s3-kubeconfig" }
}
override_resource {
  target = aws_s3_object.controlplane_yaml
  values = { id = "s3-cp" }
}
override_resource {
  target = aws_s3_object.worker_yaml
  values = { id = "s3-worker" }
}

# Scaleway overrides (needed even when inactive to avoid errors if module is not count=0)
override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = { id = "talos-img" }
}
override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = { id = "worker-img" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = { id = "11111111-0000-0000-0000-000000000001", address = "10.0.0.10/24" }
}
override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = { id = "11111111-0000-0000-0000-000000000002", address = "10.0.0.20/24" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = { id = "11111111-1111-1111-1111-111111111111", ip_address = "1.1.1.1" }
}
override_resource {
  target = module.scw.scaleway_lb_ip.k8s
  values = { id = "22222222-2222-2222-2222-222222222222", ip_address = "2.2.2.2" }
}
override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = { id = "33333333-3333-3333-3333-333333333333", address = "3.3.3.3" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway_ip.this
  values = { address = "4.4.4.4" }
}
override_resource {
  target = module.scw.scaleway_vpc_public_gateway.this
  values = { id = "44444444-4444-4444-4444-444444444444" }
}
override_resource {
  target = module.scw.scaleway_vpc_private_network.this
  values = { id = "55555555-5555-5555-5555-555555555555" }
}
override_resource {
  target = module.scw.scaleway_lb.app
  values = { id = "66666666-6666-6666-6666-666666666666" }
}
override_resource {
  target = module.scw.scaleway_lb.k8s
  values = { id = "77777777-7777-7777-7777-777777777777" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.k8s_api
  values = { id = "88888888-8888-8888-8888-888888888888" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.http
  values = { id = "99999999-9999-9999-9999-999999999999" }
}
override_resource {
  target = module.scw.scaleway_lb_backend.https
  values = { id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.k8s_api
  values = { id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.http
  values = { id = "cccccccc-cccc-cccc-cccc-cccccccccccc" }
}
override_resource {
  target = module.scw.scaleway_lb_frontend.https
  values = { id = "dddddddd-dddd-dddd-dddd-dddddddddddd" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.app
  values = { id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" }
}
override_resource {
  target = module.scw.scaleway_lb_private_network.k8s
  values = { id = "ffffffff-ffff-ffff-ffff-ffffffffffff" }
}

# ==============================================================================
# Shared variables base
# ==============================================================================

variables {
  cluster_name       = "contract-test"
  environment        = "dev"
  cluster_role       = "workload"
  talos_bootstrap    = false
  admin_ip           = ["10.0.0.1/32"]
  bastion_ssh_keys   = { scaleway = "ssh-ed25519 test" }
  git_repo_url       = "https://github.com/test/repo.git"
  argocd_namespace   = "management-gitops"
  cilium_manifest    = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-test"
  backup_s3_endpoint = "https://s3.fr-par.scw.cloud"
  backup_s3_region   = "fr-par"
  backup_s3_bucket   = "test-bucket"
}

# ==============================================================================
# Test 1: No active provider → active_provider = "none", junction point defaults
# ==============================================================================

run "no_active_provider_safe_defaults" {
  command = plan

  variables {
    node_distribution = {}
  }

  assert {
    condition     = output.active_provider == "none"
    error_message = "With no active provider, active_provider must be 'none'."
  }

  assert {
    condition     = output.k8s_lb_ip == "127.0.0.1"
    error_message = "With no active provider, k8s_lb_ip must default to 127.0.0.1."
  }

  assert {
    condition     = length(output.control_plane_private_ips) == 0
    error_message = "With no active provider, control_plane_private_ips must be empty."
  }

  assert {
    condition     = length(output.worker_private_ips) == 0
    error_message = "With no active provider, worker_private_ips must be empty."
  }
}

# ==============================================================================
# Test 2: Scaleway active → junction point picks up SCW values
# ==============================================================================

run "scaleway_active_junction_point" {
  command = apply

  variables {
    node_distribution = {
      scaleway = {
        control_planes = 3
        workers        = 1
        image_name     = "talos"
        instance_type  = "DEV1-S"
        zone           = "fr-par-1"
        region         = "fr-par"
        zones          = ["fr-par-1", "fr-par-2", "fr-par-1"]
      }
    }
  }

  assert {
    condition     = output.active_provider == "scaleway"
    error_message = "active_provider must be 'scaleway' when SCW is configured."
  }

  assert {
    condition     = output.k8s_lb_ip == "2.2.2.2"
    error_message = "k8s_lb_ip must come from the SCW module."
  }

  assert {
    condition     = output.bastion_ip == "3.3.3.3"
    error_message = "bastion_ip must come from the SCW module."
  }

  assert {
    condition     = length(output.control_plane_private_ips) == 3
    error_message = "Must have 3 control plane IPs from SCW."
  }
}

# ==============================================================================
# Test 3: OVH active → correct active_provider reported
# ==============================================================================

run "ovh_active_junction_point" {
  command = plan

  variables {
    node_distribution = {
      ovh = {
        control_planes     = 3
        workers            = 1
        region             = "GRA11"
        flavor_name        = "b2-7"
        image_id           = "dummy-talos-ovh-image"
        network_name       = "Ext-Net"
        availability_zones = ["nova"]
        bastion_image_id   = "Ubuntu 22.04"
      }
    }
  }

  assert {
    condition     = output.active_provider == "ovh"
    error_message = "active_provider must be 'ovh' when OVH is configured."
  }
}

# ==============================================================================
# Test 4: Outscale active → correct active_provider reported
# ==============================================================================

run "outscale_active_junction_point" {
  command = plan

  variables {
    node_distribution = {
      outscale = {
        control_planes     = 3
        workers            = 1
        region             = "eu-west-2"
        instance_type      = "tinav5.c2r4p1"
        image_id           = "dummy-talos-osc-image"
        availability_zones = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
        bastion_image_id   = "ami-ubuntu-mock"
      }
    }
  }

  assert {
    condition     = output.active_provider == "outscale"
    error_message = "active_provider must be 'outscale' when Outscale is configured."
  }
}

# ==============================================================================
# Test 5: cluster_role=management → correct output
# ==============================================================================

run "cluster_role_management" {
  command = plan

  variables {
    cluster_role      = "management"
    node_distribution = {}
  }

  assert {
    condition     = output.cluster_role == "management"
    error_message = "cluster_role output must reflect the management role."
  }
}

# ==============================================================================
# Test 6: cluster_role=workload → correct output
# ==============================================================================

run "cluster_role_workload" {
  command = plan

  variables {
    cluster_role      = "workload"
    node_distribution = {}
  }

  assert {
    condition     = output.cluster_role == "workload"
    error_message = "cluster_role output must reflect the workload role."
  }
}

# ==============================================================================
# Test 7: Single provider constraint — check block reports warning on violation
# OpenTofu check blocks are warnings, not errors; they don't fail plans.
# This test validates the constraint is evaluated correctly.
# Note: actual multi-provider violation would trigger a check block warning;
# the constraint is documented at check "single_provider_per_cluster".
# ==============================================================================

run "single_provider_constraint_metadata" {
  command = plan

  variables {
    node_distribution = {
      scaleway = {
        control_planes = 1
        workers        = 0
        image_name     = "talos"
        instance_type  = "DEV1-S"
        zone           = "fr-par-1"
        region         = "fr-par"
        zones          = ["fr-par-1"]
      }
    }
  }

  assert {
    condition     = length(local.active_providers) == 1
    error_message = "Exactly one provider must be active in this configuration."
  }
}
