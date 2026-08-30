"""provider-contract.md § 4, "Security groups": inbound default policy MUST
be drop (#123).

Two providers expose this as an actual attribute to check — Scaleway's
`inbound_default_policy` and OpenStack's `delete_default_rules` (which
removes OpenStack's own auto-created default-allow rules, the mechanism
this project's own security.tf comments already name as the equivalent).
Outscale's `outscale_security_group` has no such attribute at all: it is
an AWS-style security group, default-deny on ingress by construction, with
nothing to misconfigure — so it is deliberately not in scope below rather
than checked against an attribute that does not exist. Proxmox declares no
security-group-shaped resource in this repository yet; nothing to check
until it does.
"""

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck

# resource type -> (attribute, required value)
DROP_RULE = {
    "scaleway_instance_security_group": ("inbound_default_policy", "drop"),
    "openstack_networking_secgroup_v2": ("delete_default_rules", True),
}


class InboundDefaultDrop(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name='Security group inbound default policy must be drop (provider-contract.md § "Security groups")',
            id="CKV_OA_2",
            categories=[CheckCategories.NETWORKING],
            supported_resources=list(DROP_RULE.keys()),
        )

    def scan_resource_conf(self, conf):
        attr, expected = DROP_RULE[self.entity_type]
        value = conf.get(attr)
        if not value or value[0] != expected:
            return CheckResult.FAILED
        return CheckResult.PASSED


check = InboundDefaultDrop()
