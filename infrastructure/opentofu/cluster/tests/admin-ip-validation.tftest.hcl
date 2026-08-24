# admin_ip is the allowlist in front of bastion sshd AND the 6443 ACL. Until
# this suite existed, nothing in the repository read a CIDR or an ACL, so
# `["0.0.0.0/0"]` was accepted in silence and opened both on every provider at
# once — in front of a `system:masters` kubeconfig Kubernetes cannot revoke.
#
# Every run plans with `node_distribution = {}`: no provider module activates,
# so the suite needs none of the ~15 override_resource blocks scaleway.tftest.hcl
# carries, and stays about the variable rather than about Scaleway. The mocks
# are still declared because the root references those providers — `local`
# included, since local_file writes kubeconfig/talosconfig into the module
# directory and an unmocked run would overwrite a live cluster's credentials,
# then delete them on teardown.
#
# A valid CIDR reaching the PROVIDERS is proven elsewhere and deliberately not
# recopied: scaleway.tftest.hcl and k8s-lb-mode.tftest.hcl both plan the full
# root with a routine admin_ip, so a rule that is too strict turns them red.

mock_provider "scaleway" {}
mock_provider "openstack" {}
mock_provider "outscale" {}
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "local" {}

variables {
  cluster_name        = "test-cluster"
  environment         = "dev"
  cluster_role        = "management"
  talos_bootstrap     = false
  backup_enabled      = false
  node_distribution   = {}
  admin_ip            = ["203.0.113.4/32"] # RFC 5737 TEST-NET-3
  git_repo_url        = "https://github.com/test/repo.git"
  cilium_manifest     = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium"
  s3_primary_endpoint = "https://s3.fr-par.scw.cloud"
  s3_primary_region   = "fr-par"
  s3_replica_endpoint = "https://s3.fr-par.scw.cloud"
  s3_replica_region   = "fr-par"
}

# --- Accepted. Without these the suite could go green by refusing everything,
# which is the shape of defect this repository keeps finding. ---

run "a_routine_cidr_is_accepted" {
  command = plan

  assert {
    condition     = length(var.admin_ip) == 1
    error_message = "A single /32 is the ordinary case and must survive validation."
  }
}

run "several_cidrs_are_accepted" {
  command = plan
  variables {
    admin_ip = ["203.0.113.4/32", "198.51.100.0/24", "10.0.0.0/8"]
  }

  assert {
    condition     = length(var.admin_ip) == 3
    error_message = "A second operator, an office range and a private on-premise range are all legitimate."
  }
}

# --- Refused. ---

run "the_whole_internet_is_refused" {
  command = plan
  variables {
    admin_ip = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_ip]
}

run "the_whole_internet_is_refused_in_ipv6" {
  command = plan
  variables {
    admin_ip = ["::/0"]
  }
  expect_failures = [var.admin_ip]
}

# A /0 behind a routable-looking address: matching the string "0.0.0.0/0" would
# let this through, which is why the rule reads the prefix instead.
run "a_zero_prefix_on_a_real_address_is_refused" {
  command = plan
  variables {
    admin_ip = ["198.51.100.7/0"]
  }
  expect_failures = [var.admin_ip]
}

# One good entry does not license a bad one — the security groups iterate the
# whole list, so a single /0 anywhere in it opens the door.
run "one_bad_entry_among_good_ones_is_refused" {
  command = plan
  variables {
    admin_ip = ["203.0.113.4/32", "0.0.0.0/0"]
  }
  expect_failures = [var.admin_ip]
}

run "an_empty_list_is_refused" {
  command = plan
  variables {
    admin_ip = []
  }
  expect_failures = [var.admin_ip]
}

run "a_bare_address_without_a_prefix_is_refused" {
  command = plan
  variables {
    admin_ip = ["203.0.113.4"]
  }
  expect_failures = [var.admin_ip]
}

# The placeholder every *.tfvars.example ships. A copied-but-unedited env file
# must fail here, by name, rather than at the provider API.
run "the_unedited_example_placeholder_is_refused" {
  command = plan
  variables {
    admin_ip = ["YOUR_IP/32"]
  }
  expect_failures = [var.admin_ip]
}
