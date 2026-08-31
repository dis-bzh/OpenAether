"""provider-contract.md § "Node image drift" (#123).

Every control_plane/worker node resource must ignore its boot-image
attribute. talosctl upgrade changes the running version without touching
the cloud resource, so after an upgrade the two disagree by design — and
without the ignore, a routine `tofu apply` replaces every node at once
(all control planes together => etcd loses quorum). Bastions are exempt:
they run plain Ubuntu, never `talosctl upgrade`d, so there is nothing to
diverge.

Checkov ships no policy family for Scaleway, Outscale or Proxmox, and
gives OpenStack nothing that reads this project's own `lifecycle` block —
this check is what makes the contract's rule enforced instead of merely
documented, for all four providers checked here.
"""

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck

# One entry per node resource type this repository declares. The value is the
# exact ignore_changes element the contract requires — verified against each
# provider's own main.tf, not guessed: `image` (Scaleway), `image_id`
# (OpenStack, Outscale), `disk[0].file_id` (Proxmox, where the image lives
# inside a nested block, not a top-level attribute).
IMAGE_ATTRIBUTE = {
    "scaleway_instance_server": "image",
    "openstack_compute_instance_v2": "image_id",
    "outscale_vm": "image_id",
    "proxmox_virtual_environment_vm": "disk[0].file_id",
}


class NodeImageDrift(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name='Node resource must ignore boot-image drift (provider-contract.md "Node image drift")',
            id="CKV_OA_1",
            categories=[CheckCategories.GENERAL_SECURITY],
            supported_resources=list(IMAGE_ATTRIBUTE.keys()),
        )

    def scan_resource_conf(self, conf):
        # __address__ is "module.<provider>.<resource_type>.<local_name>" —
        # the one place Checkov exposes the Terraform block name to a
        # resource-level check, and how bastion instances (same resource
        # TYPE, out of scope for this rule) are told apart from the two that
        # matter. Split on "." first, THEN strip a for_each/count index —
        # "control_plane" never carries one, but being liberal here costs
        # nothing and a proxmox bastion's "bastion[0]" must not survive as
        # a local name that happens to match neither branch by accident.
        address = conf.get("__address__", "")
        local_name = address.rsplit(".", 1)[-1].split("[", 1)[0]
        if local_name not in ("control_plane", "worker"):
            return CheckResult.PASSED

        required = IMAGE_ATTRIBUTE.get(self.entity_type)
        lifecycle = conf.get("lifecycle")
        if not lifecycle or not isinstance(lifecycle, list) or not isinstance(lifecycle[0], dict):
            return CheckResult.FAILED

        ignore_changes = lifecycle[0].get("ignore_changes")
        if not ignore_changes:
            return CheckResult.FAILED
        # HCL block-attribute wrapping: one list per block instance, so the
        # actual entries are ignore_changes[0].
        entries = ignore_changes[0] if isinstance(ignore_changes[0], list) else ignore_changes
        return CheckResult.PASSED if required in entries else CheckResult.FAILED


check = NodeImageDrift()
