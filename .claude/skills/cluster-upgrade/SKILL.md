---
name: cluster-upgrade
description: Upgrading Kubernetes and Talos on a live OpenAether cluster without taking the API down. Use when bumping talos_version or kubernetes_version, running rolling-replace, or investigating a node that did not come back.
---

# Upgrading a live cluster

`docs/upgrade.md` is the procedure, and `scripts/dev/staging-upgrade.sh` is that
same procedure unattended — if the two disagree, the script wins, it is the one
that runs. This is the reasoning behind both.

## Upgrade in place; do not replace the node

`rolling-replace.sh --upgrade` calls `talosctl upgrade`, which keeps the node's
disk, identity and etcd membership, drains it, and refuses a control-plane
upgrade that would cost etcd quorum. Replacing the VM throws all of that away and
rebuilds it — which is what used not to work on OVH. Replacement remains correct
for anything that is **not** a version change.

## Check the pair before moving either

Talos supports the current Kubernetes minor and the five before it. Both the
starting and the ending pair must sit inside that window, and so must the
intermediate state, because one moves before the other. `versions-guard.tf`
refuses an unsupported pair and refuses a Talos minor it has never heard of —
extend its map from the upstream matrix rather than widening it.

## Expect two applies, and know why

Bumping `talos_version` and applying puts the new installer into the machine
configs; nothing reboots yet. That first apply fails once with "Provider produced
inconsistent final plan" on OVH and Outscale. Run it again.

Not a sign you did something wrong, and no longer a mystery: upstream
`siderolabs/terraform-provider-talos` #352. When `machine_configuration_input` is
unknown at plan time, the provider keeps the old `machine_configuration_hash` in
the plan and recomputes it at apply. The second run works because the first
resolved whatever was unknown. Fixed upstream in the 0.12.0 pre-release line
only — we pin 0.11.0, the newest stable. **Do not "fix" it locally without
proving the fix on a real cloud**, and do not add a retry: `staging-upgrade.sh`
deliberately has none, because a retry turns the defect green.

## What to watch, beyond "it came back"

- **The node's name is unchanged.** A `talos-xxxxx` entry means the hostname did
  not hold; the next reboot orphans another node object, and
  `data.talos_cluster_health` then blocks `tofu plan` itself.
- **etcd still lists every member** — by peer URL, not by name: a member keeps the
  name it joined under, so a renamed node no longer matches by hostname.
- **A number for the interruption.** One-second probe against the kubeconfig's
  endpoint — not a tunnel to one node, since the node you are upgrading is
  expected to go away.
- **`tofu plan` clean afterwards.** If it wants to replace nodes, the boot image
  and the running version have disagreed, and that plan would take the cluster
  down.

## A stuck drain is one budget's fault, not the stack's

A worker drains clean — measured 2026-08-13, exit 0, zero non-DaemonSet pods
left. It did not before, and the cause was singular: `istiod` ran one replica
under a budget requiring one available, so it could never be evicted. It runs two
now.

The remaining zero-disruption budgets are correct and transient — CNPG guards
each cluster's primary until a switchover, Longhorn blocks while volumes are
attached, OpenBao wants 2 of 3 raft replicas. If a drain hangs, look for a
single-replica workload under a `minAvailable: 1` before concluding the stack
cannot be drained. That wrong conclusion was written into a release note and had
to be corrected in public.
