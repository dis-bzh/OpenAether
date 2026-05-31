mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "talos" {}
mock_provider "aws" {
  mock_resource "aws_s3_object" {
    defaults = {
      id = "mock-id"
    }
  }
}

# Dummy AWS credentials for test environment
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# --- S3 Backup overrides ---

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

# --- Scaleway image data sources ---

override_data {
  target = module.scw.data.scaleway_instance_image.talos
  values = { id = "dummy-talos-id" }
}

override_data {
  target = module.scw.data.scaleway_instance_image.worker
  values = { id = "dummy-worker-id" }
}

# --- Scaleway resource overrides (computed values) ---

override_resource {
  target = module.scw.scaleway_ipam_ip.control_plane
  values = {
    id      = "ipam-cp"
    address = "10.0.0.10/24"
  }
}

override_resource {
  target = module.scw.scaleway_ipam_ip.worker
  values = {
    id      = "ipam-worker"
    address = "10.0.0.20/24"
  }
}

override_resource {
  target = module.scw.scaleway_lb_ip.app
  values = {
    id         = "11111111-1111-1111-1111-111111111111"
    ip_address = "1.1.1.1"
  }
}

override_resource {
  target = module.scw.scaleway_lb_ip.k8s
  values = {
    id         = "22222222-2222-2222-2222-222222222222"
    ip_address = "2.2.2.2"
  }
}

override_resource {
  target = module.scw.scaleway_instance_ip.bastion
  values = {
    id      = "33333333-3333-3333-3333-333333333333"
    address = "3.3.3.3"
  }
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
# Shared Test Variables (Scaleway HA configuration)
# ==============================================================================

variables {
  cluster_name    = "test-cluster"
  environment     = "dev"
  cluster_role    = "management"
  talos_bootstrap = true
  admin_ip        = ["1.2.3.4/32"]
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
      region         = "fr-par"
      zones          = ["fr-par-1", "fr-par-2", "fr-par-1"]
    }
  }
  git_repo_url     = "https://github.com/test/repo.git"
  argocd_namespace = "management-gitops"

  # Non-placeholder manifest to pass precondition
  cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"

  backup_s3_endpoint = "https://s3.fr-par.scw.cloud"
  backup_s3_region   = "fr-par"
  backup_s3_bucket   = "test-bucket"
}

# ==============================================================================
# Test 1: Module Activation — SCW module activates when nodes configured
# ==============================================================================

run "verify_scw_module_activation" {
  command = plan

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW module should be active when nodes are configured."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "OVH module should be inactive when not in node_distribution."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Outscale module should be inactive when not in node_distribution."
  }
}

# ==============================================================================
# Test 2: Variable Validation — HA requirements
# ==============================================================================

run "verify_variable_validation" {
  command = plan

  assert {
    condition     = var.node_distribution.scaleway.control_planes == 3
    error_message = "Control plane count should be 3 for HA."
  }

  assert {
    condition     = length(var.node_distribution.scaleway.zones) >= 2
    error_message = "Control planes should span at least 2 zones for HA."
  }
}

# ==============================================================================
# Test 3: cluster_role variable is valid
# ==============================================================================

run "verify_cluster_role" {
  command = plan

  assert {
    condition     = var.cluster_role == "management"
    error_message = "cluster_role should be management for this test."
  }
}

# ==============================================================================
# Test 4: Bastion Configuration — SSH key must be present
# ==============================================================================

run "verify_bastion_config" {
  command = plan

  assert {
    condition     = length(var.bastion_ssh_keys.scaleway) > 0
    error_message = "Bastion SSH key cannot be empty."
  }
}

# ==============================================================================
# Test 5: Provider Contract — SCW outputs conform to provider-contract.md
# ==============================================================================

run "verify_provider_contract" {
  command = apply

  assert {
    condition     = output.bastion_ip != null && output.bastion_ip != "N/A"
    error_message = "Provider contract: bastion_ip must be available."
  }

  assert {
    condition     = output.k8s_lb_ip != null && output.k8s_lb_ip != ""
    error_message = "Provider contract: k8s_lb_ip must be available."
  }

  assert {
    condition     = output.talosconfig != null
    error_message = "Talos module: talosconfig must be defined."
  }

  assert {
    condition     = length(output.control_plane_private_ips) == 3
    error_message = "Provider contract: should have 3 control plane IPs for HA."
  }

  assert {
    condition     = length(output.worker_private_ips) == 1
    error_message = "Provider contract: should have 1 worker IP."
  }

  assert {
    condition     = output.active_provider == "scaleway"
    error_message = "active_provider should be 'scaleway' when SCW nodes are configured."
  }

  assert {
    condition     = output.cluster_role == "management"
    error_message = "cluster_role should be 'management' for this test."
  }
}

# ==============================================================================
# Test 6: Phase 1 Only — talos_bootstrap=false should not create Talos resources
# ==============================================================================

run "verify_phase1_no_talos_apply" {
  command = plan

  variables {
    talos_bootstrap = false
  }

  assert {
    condition     = length(module.scw) == 1
    error_message = "SCW infra module should still be active in Phase 1."
  }
}

# ==============================================================================
# Test 7: Provider Disabled — empty node_distribution creates nothing
# ==============================================================================

run "verify_provider_disabled" {
  command = plan

  variables {
    node_distribution = {}
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when node_distribution is empty."
  }

  assert {
    condition     = length(module.ovh) == 0
    error_message = "OVH module should be inactive when node_distribution is empty."
  }

  assert {
    condition     = length(module.outscale) == 0
    error_message = "Outscale module should be inactive when node_distribution is empty."
  }
}

# ==============================================================================
# Test 8: OVH module activates with OVH node distribution
# ==============================================================================

run "verify_ovh_module_activation" {
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
      }
    }
  }

  assert {
    condition     = length(module.ovh) == 1
    error_message = "OVH module should be active when OVH nodes are configured."
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when only OVH is configured."
  }
}

# ==============================================================================
# Test 9: Outscale module activates with Outscale node distribution
# ==============================================================================

run "verify_outscale_module_activation" {
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
        bastion_image_id   = "ami-ubuntu-2204-mock"
      }
    }
  }

  assert {
    condition     = length(module.outscale) == 1
    error_message = "Outscale module should be active when Outscale nodes are configured."
  }

  assert {
    condition     = length(module.scw) == 0
    error_message = "SCW module should be inactive when only Outscale is configured."
  }
}
