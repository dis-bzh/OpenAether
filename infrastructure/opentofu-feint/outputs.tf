# Ids the runner re-reads straight from the emulator: a state file that agrees
# with itself is not evidence that a resource exists, or that it is gone.
#
# Splats, not indexes: the inactive provider's resources have count 0, and a
# [0] there fails at evaluation even inside the branch of a conditional.

output "scaleway_paths" {
  description = "Emulator paths probed after apply (200) and after destroy (404)."
  # Ids are locality-qualified, "fr-par-1/<uuid>"; the path carries the zone
  # itself, so only the uuid goes in it.
  value = [
    for id in concat(
      scaleway_instance_server.control_plane[*].id,
      scaleway_instance_server.worker[*].id,
      scaleway_instance_server.bastion[*].id,
    ) : "/instance/v1/zones/fr-par-1/servers/${element(split("/", id), 1)}"
  ]
}

output "outscale_vm_ids" {
  description = "Ids the runner checks through ReadVms after apply and after destroy."
  value = concat(
    outscale_vm.control_plane[*].vm_id,
    outscale_vm.worker[*].vm_id,
    outscale_vm.bastion[*].vm_id,
  )
}
