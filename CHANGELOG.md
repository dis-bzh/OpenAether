# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file used to document 1.0.0, 1.0.0-withdrawn and 1.1.0. Those tags and
releases were deleted from both repositories and none of them ever worked; a
changelog listing releases nobody can obtain is not a changelog. That history is
in git. 0.1.0 is the first entry describing something proven.

---

## [0.1.0] — unreleased

**One Talos cluster, on one supported cloud, with one fixed foundation: Cilium.**
Infrastructure only — nothing above that layer. Start at
[`docs/first-cluster.md`](docs/first-cluster.md).

### Added

- **Every task is `<noun>-<verb>`**: `cluster-up`, `infra-plan`, `infra-apply`,
  `tunnels-up`, `cluster-verify`, `cluster-upgrade`, `cluster-roll`,
  `infra-down`, `cluster-down`. Upgrades:
  [`docs/upgrade.md`](docs/upgrade.md). Day-1 access:
  [`docs/admin-access.md`](docs/admin-access.md).
- **An approval you cannot lose by accident.** `APPROVE=auto|ask` names *who*
  answers the question, never whether one is asked: every apply plans to a file
  and applies that file, and `tofu apply <saved plan>` does not prompt.
  `-auto-approve` is gone from the cloud path, CI included. Destroy always takes
  two commands and no flag collapses them.
- **State and artifacts encrypted client-side in S3**, with an optional replica
  on a second cloud. S3 credentials are namespaced by the cloud that *holds the
  bucket*, not by the cluster. Proven across providers: an encrypted tfstate at
  Outscale while the cluster ran on Scaleway.

### Validated

Measured on real accounts on 2026-08-19, on Scaleway and on OVH. Versions were
read back from the kubelets and from each node's own Talos API, never from the
tool that performed the upgrade.

- **Scaleway, from an empty account**: deploy in 8 min 50 for 72 resources,
  `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos
  v1.13.7 → v1.13.8 confirmed by Talos itself on 6/6 nodes (`stage=running`,
  fallback dropped).
- **OVH**: the same five pillars — deploy, verify, idempotency, and both
  upgrades — the same versions, 11/11, idempotency 3/3.
- **Idempotency is three assertions, not one**: an empty plan, the *same* nodes
  (name and `creationTimestamp`), and a kubeconfig that still reaches the
  apiserver. An empty plan alone would not catch a node replaced underneath it.
- **An upgrade is not seamless.** Longest apiserver outage 5 s on Scaleway (16
  failed probes out of 575) and 7 s on OVH (9-10 out of ~540). Both are *worse*
  than the best figures this project ever recorded (3 s and 1 s). Plan for a gap.
- **313 offline assertions across 11 harnesses**, every one mutation-tested
  (`task test`). The emulated lane runs feint 0.9.0 against Scaleway provider
  2.81.0 — the same version the clusters run.

### Fixed

- **The shared schematic shipped `siderolabs/qemu-guest-agent`, and that one
  extension cost every upgrade.** It never starts on OVH or Outscale, whose
  images carry no `hw_qemu_guest_agent` device: the boot sequence never
  completed, Stage never became Running, the META Upgrade key was never dropped,
  and the next reboot reverted the upgrade the tool had just reported as
  successful. Root cause, not a workaround.

### Known limits

Read these before deploying something that matters. Open items:
[`docs/backlog.md`](docs/backlog.md).

- **No Flux and no applications.** `deploy_flux` defaults to `false`. Flux is
  disabled, not amputated — the Talos module already reads an empty manifest as
  "no Flux", so turning it on moves no resource address — and it returns as a
  user choice in a later release. Everything it reconciles lives in
  `OpenAether-apps`.
- **No CAPI and no multi-cluster.** A management cluster is an optional overlay
  on top of this, never the entry point.
- **Outscale is blocked upstream, not by us.** A load balancer sat in
  `provisioning` for over an hour, and afterwards the Net, its subnet and its
  internet service refused deletion while the account held 0 VMs, 0 volumes, 0
  load balancers, 0 public IPs, 0 NAT services and 0 NICs. Outscale support
  request 399530 is open. The provider module stays in the repository; the
  release does not claim it.
- **Scaleway and OVH are the clouds that were measured.** Proxmox has never been
  applied on real hardware; the local Docker rung proves `modules/talos` without
  credentials and nothing about a cloud. Anything else is code, not a claim.
