# Where we stand

What runs, what has been measured on a real account and when, and what is still
unproven. This is the first file to open at the start of a session: it says where
to pick up.

Open work is **not** here — it is in the GitHub issues, each naming what closes it
and the rung it needs. This file answers "what is true today", not "what is left".

**0.1.0 is the first release that will ship something proven.** Every 1.x tag was
deleted on both repositories; the versions they named never worked. Scope:
**one Talos cluster on one supported provider, floor = Cilium**. Flux is disabled
by default (`deploy_flux`, false) — disabled, not amputated, and it returns as a
user choice. CAPI and multi-cluster are an optional overlay, never the entry point.

**Measured on real clouds, from an empty account** — Scaleway and OVH on
2026-08-19, Outscale on 2026-08-20. This is the evidence the release rests on.

| | deploy | `task cluster-verify` | idempotency | k8s | Talos | longest outage |
|---|---|---|---|---|---|---|
| Scaleway | ✅ 8 min 50, 72 resources | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 5 s (16 fails in 575) |
| OVH | ✅ | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 7 s (9-10 in ~540) |
| Outscale | ✅ 51 resources, then 17 | ✅ 11/11 | ✅ 3/3 | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes 1.13.7→1.13.8 | 8 s (59 in 1179) |

Three things about that table are the point of it:

- **Versions were read from the kubelets and from each node's own Talos API**,
  never from the tool that performed the upgrade. Talos itself reports
  `stage=running` on 6/6 and the META upgrade fallback dropped — so the upgrade
  survives a reboot, which is what the earlier "6/6 report the new version" never
  established.
- **Idempotency is three assertions, not one**: an empty plan, the SAME nodes
  (name and creationTimestamp), and a kubeconfig that still reaches the apiserver.
- **The interruption got WORSE, and that is a regression, not a footnote.** The
  earlier records were 3 s on Scaleway, 1 s on OVH and 1 s on Outscale. All three
  clouds moved the same way in the same week. First entry below.

**Scaleway re-run on 2026-08-20**, after the roll was changed to take the etcd
leader last: `cluster-up` → `cluster-up` → `cluster-upgrade` → `cluster-up`, all
four green. The two re-runs are the idempotency evidence and they are the command
itself, not a script — `No changes.` on all three roots, `0 added, 0 changed, 0
destroyed`. **The second re-run is new**: idempotency AFTER an upgrade had never
been checked, and it holds because `cluster-upgrade` writes the new pin back into
the tfvars, so a later `cluster-up` does not try to revert. Longest outage 2 s
(13 fails in 577) — see [`upgrade.md`](upgrade.md) for why that does NOT establish
the leader-last fix: that run moved Talos only, the 5 s one also moved Kubernetes.

**What the release delivers besides a cluster.** Every task is `<noun>-<verb>`
(`cluster-up`, `infra-plan/apply/down`, `tunnels-up`, `cluster-verify/upgrade/roll/down`).
`APPROVE=auto|ask` names WHO answers the approval, never whether there is one:
every apply plans to a file and applies THAT file, and a saved plan never prompts.
Destroy always takes two commands and no flag collapses them. S3 credentials are
namespaced by the cloud that HOLDS the bucket, and a cross-provider backup is
proven — an encrypted tfstate at Outscale while the cluster runs on Scaleway.
406 offline assertions across 13 harnesses, every one mutation-tested — 330 of
them from the eleven harnesses that existed before Cléa, three fewer than the
333 this page claimed and nothing had re-counted since; the emulated lane runs
feint 0.10.0 against Scaleway provider 2.81.0, the version the clusters run.

**The root cause behind a week of upgrade failures is fixed**, and it was ours:
the shared schematic shipped `siderolabs/qemu-guest-agent`, which never starts on
OVH or Outscale (no `hw_qemu_guest_agent` on the image, so the virtio port it
waits for never appears). The boot sequence never finished, Stage never became
Running, the META `Upgrade` key was never dropped, and the next reboot reverted
the upgrade — one extension behind the hung watch, the lost upgrade and the revert.

**Outscale needs a fresh Net, and leaves one behind.** The LBU that sat in
`provisioning` for over an hour was diagnosed by Outscale as a timeout inside
their own load balancer service: it stops waiting after 10 s for an internal VM
that takes about 10.7, so the workflow fails, the resources it already created
stay, and the LBU never leaves `provisioning`. Their instruction is to create no
further LBU in that Net and use a new one — a redeploy on a fresh Net succeeded
on 2026-08-20, the new LBU `active` with 3 backends, and **request 399530 is
closed**. One Net from before the fix still refuses deletion on a dependency no
read returns; only Outscale can clear that, and a second request is open for it.

**Dependency watch, since 2026-08-24.** Cléa (`scripts/clea/`, `docs/clea.md`)
reads every version this repository claims, resolves what upstream published,
and probes a bump by installing it from cold and upgrading over the old one in
a bare container — daily for tools, weekly for the local Talos/Kubernetes pair,
never for a cloud. Renovate keeps proposing the bumps; Cléa watches, probes and
reports into one issue, rewritten in place.

It found nine of twenty-one version anchors inert (Renovate had never been told
to read them, now fixed), and that Renovate had proposed nothing since its
config landed — its nine pull requests predate `renovate.json5` by three hours,
and helm 4.2.4 (published 2026-08-13) and flux 2.9.4 (2026-08-07) both sat
unproposed through their scheduled windows. The schedule is now daily; whether
that alone was the cause is [#88](https://github.com/dis-bzh/OpenAether-infra/issues/88).

Running it, on a workstation rather than only in CI, found five more defects
that a green pipeline never showed: `command -v sudo` asking whether sudo
*exists* rather than whether it can be *used* (eight sites); `install_tofu`
preferring snap, which cannot install a named version; a tool's version
assembled from two commands; the CoreDNS readiness gate failing on a cluster it
had just watched come up; and the teardown proof printing nothing on a clean
account, indistinguishable from a check that never ran. All five are fixed.

**The local lane's pin mismatch is measured, not yet closed.** Talos `v1.13.9` /
Kubernetes `v1.36.4` — upstream's current pair — boots on the Docker lane:
`task local-verify` 6/6. The two roots still pin different versions, and no
real cloud has run the newer pair — [#87](https://github.com/dis-bzh/OpenAether-infra/issues/87).

**Not proven**: no lane has ever run unattended to completion; nobody has
deployed under a non-empty `bucket_suffix`; and the failover — provider A treated
as gone, the cluster rebuilt on B from B's replica alone — has never been
attempted.

**Resume here**: the interruption regression, then rolling-replace's two blind
applies, then decide whether 0.1.0 ships a staging lane at all.
