---
name: cluster-upgrade
description: Upgrading Kubernetes and Talos on a live OpenAether cluster without taking the API down. Use when bumping talos_version or kubernetes_version, running rolling-replace, or investigating a node that did not come back.
---

# Upgrading a live cluster

`docs/release-checklist.md` §7 is the procedure. This is the reasoning behind it.

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

## Expect two applies

Bumping `talos_version` and applying puts the new installer into the machine
configs; nothing reboots yet. That first apply fails once with "Provider produced
inconsistent final plan" on OVH and Outscale. Run it again. It is a known open
item, not a sign you did something wrong.

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

## The drain does not finish, and that is known

Several PodDisruptionBudgets permit no eviction — CNPG guards each cluster's
primary until a switchover, Longhorn blocks while volumes are attached. The
script reports the stuck drain, waits out its timeout and continues, so the node
reboots with those pods aboard. Nothing observable has broken, but "drained
before reboot" is not a property this project can claim yet. See the backlog.
