# Release checklist — 1.0.1

English only, like `backlog.md`: rewritten each release, and two copies would drift.

What to run before tagging 1.0.1 and telling anyone about it. Ordered by what
fails cheapest. **Stop at the first red** — every later step assumes the earlier
ones held.

Record the result next to each line as you go. A line with no result is a line
nobody ran, and that is the answer this checklist exists to make visible.

---

## 0. Before anything: what this release changed and nobody has run

Five behaviours changed in this cycle and **none was exercised outside a
container**. They are the reason this checklist is not just the usual matrix.

| What changed | Why it needs a real run |
|---|---|
| `task local-up` renders Cilium when missing | The whole chain was verified by reading, not running — Docker was unavailable |
| Local ports derive from `talos_api_port_base` | `local-status` and `test-talos-local.sh` were dialling a port that is never published |
| `git_ref` → `ref.name` on the Flux `GitRepository` | `ref.name` under Flux 2.9.3 has never been applied to a cluster |
| The Longhorn `HTTPRoute` left the default build | Nobody has confirmed the gateway comes up without it, or that Longhorn itself still works |
| `setup.sh` installs `helm`, reports missing `nc` | Never run on a clean machine |

---

## 1. Clean-machine bootstrap (the first five minutes)

The point is a **fresh clone in a fresh directory**. Your working tree has files
a clone does not — that is exactly how the CNI defect survived.

```bash
cd $(mktemp -d)
git clone https://github.com/dis-bzh/OpenAether-infra
cd OpenAether-infra && git checkout <the 1.0.1 candidate>
./scripts/setup.sh
```

Your workstation is not a clean machine and a fresh clone on it proves little —
run this in a bare container instead, which is what a newcomer actually meets:

```bash
git archive --format=tar HEAD > /tmp/repo.tar
docker run --rm -v /tmp/repo.tar:/tmp/repo.tar:ro ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
  mkdir /oa && tar -xf /tmp/repo.tar -C /oa && cd /oa && ./scripts/setup.sh'
```

- [x] `setup.sh` completes and installs **helm** (`command -v helm`)
      → 2026-08-12: exit 0, and tofu/talosctl/kubectl/task/flux/helm/yamllint all
      present. Before `c5ec82f` this exited 1 having installed **nothing**:
      unzip and gpg missing (OpenTofu's installer refuses without them), then
      `sudo` missing as root, and `set -e` turned each into a total abort.
- [x] it warns if `nc` is absent, and does not claim to install it → yes
- [x] every command the README quick start names exists (`task --list`) → exit 0

## 2. Local Docker — the credential-free rung

Still in the **fresh clone**, no `.env.sh`, no credentials in the shell.

```bash
task local-up
task local-status
task local-test
task local-down
```

- [x] `local-up` renders `cilium-local.yaml` itself (watch for the render step)
      → yes, from a tree with the manifest removed
- [x] **Cilium is actually running** — `kubectl -n kube-system get pods -l k8s-app=cilium`.
      This is the one that was broken. A cluster whose pods are Pending with no
      CNI still looks like a successful apply. → 6/6 Running
- [x] `local-status` prints etcd members — it dialled the wrong port until now
      → 3 members listed
- [x] `local-test` reaches its green banner **and** its checks are fatal.
      Do NOT test this by stopping a container: the script re-applies before it
      checks, so tofu simply recreates it. Break something the apply will not
      put back — `kubectl -n kube-system delete daemonset cilium` — then run the
      Step 4 checks. → `01a081a`: the old lines warned and exited 0 on 0/6 pods,
      the new ones exit 1.
- [x] `local-down` leaves no container, volume or network behind. Diff against a
      snapshot taken before `local-up`; a bare `docker ps -a` on a workstation
      lists every other project you have ever run. → nothing left

Then repeat `local-up` **with the manifest already rendered** — the normal case
for you — and confirm it does not re-render needlessly. → no render step, and
the manifest's checksum is unchanged.

## 3. Emulated cloud — no account, real provider binaries

```bash
task feint-up
task feint-test                        # both providers, plan + CRUD
task feint-record PROVIDER=scaleway
task feint-record PROVIDER=outscale
task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com   # must REFUSE
task feint-down
```

- [x] both providers green on plan and on the apply/destroy cycle
      → Feint 0.7.0: scaleway 8 resources, outscale 27, each with an empty
      re-plan and a destroy confirmed against the API
- [x] the ranking still shows the four known operations and no new one
      → 3 on Scaleway (`ipam BookIP`, `lb ips`, `vpc-gw ips`), 1 on Outscale
      (`CreateLoadBalancer`)
- [x] the guard refuses a non-loopback endpoint — checked both ways, as a Task
      variable and as an environment variable:
      `task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com`
      must print `endpoint … is not local` and exit non-zero. It did NOT until
      2026-08-11: a Task variable is not an environment variable, so the script
      never saw the value and this test passed without testing anything.

## 4. Cloud — Scaleway first, it is the reference

Use a **throwaway project**, not one holding anything real. Non-HA to keep the
bill down unless the line says otherwise.

```bash
source .env.sh
cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars{.example,}
$EDITOR infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
task talos-image PROVIDER=scaleway
task up ROLE=management PROVIDER=scaleway KEY=~/.ssh/your-key
```

`preflight-quotas` has no Scaleway backend — it takes `ovh` or `outscale` only.
`task up` now refuses before spending if the env file or the SSH key is missing;
it used to check the key in phase 2, i.e. after `infra` had created VMs.

- [x] **`SCW-mgmt-ha`** — 3 CP across 3 AZs, run instead of the cheaper non-HA
      path. 6 nodes Ready, k8s v1.36.3, Cilium on all six. The multi-AZ etcd
      case the matrix ranks highest had never been applied; it has now.
      Two defects surfaced on the way, both in the backlog: the bootstrap
      resource is not idempotent despite its comment, and its retry is
      unbounded — it ran 2h46 against billed resources before being stopped.
- [ ] the apps `GitRepository` resolves the ref you pinned:
      `kubectl -n flux-system get gitrepository openaether -o yaml | grep -A3 'ref:'`
      → this is the **`ref.name` change**, and the first time it meets Flux.
      ⚠️ Pin a **tag** for this, deliberately. `OpenAether-apps` has never been
      tagged at all, the real `envs/*.tfvars` carry no `git_ref` line and so fall
      back to `refs/heads/main`, and the twelve `.example` files point at
      `refs/tags/…` — a ref that has never existed and that no deployment has
      ever resolved. Tag apps first, set `git_ref` to it, and check it here.
      → **done, and it works**: apps tagged `1.1.0-rc1` (its first tag ever),
      `git_ref` pinned to it, GitRepository Ready=True with
      `artifact.revision = refs/tags/1.1.0-rc1@sha1:9918021…`.
- [~] every Flux Kustomization Ready: `flux get kustomizations -A`
      → 29/36. Six wait on a cascade behind `cnpg`, whose ExternalSecrets for
      the backup S3 credentials cannot sync: seeding those into OpenBao is the
      manual per-cluster step the backlog records as deliberate. The
      auto-generated secrets did sync. The seventh is `clusterctl-inventory`,
      already open in the backlog. Nothing here is a new defect — but the box
      cannot be ticked without seeding, so say so rather than call it green.
- [x] **no Longhorn HTTPRoute**: `kubectl -n longhorn-system get httproute`
      → empty, and Longhorn runs anyway (23 pods). Both Gateways came up with
      their LB-IPAM VIPs. Adding the route back by hand is still untested.
- [x] **idempotency**: `task up` a second time → 0 changes, node ages unchanged,
      kubeconfig still valid → "0 added, 0 changed, 0 destroyed" on both phases,
      nodes aged only by the elapsed minute.
- [x] `task etcd-snapshot PROVIDER=scaleway` writes to both buckets → 49 MB,
      encrypted, in the primary and its `-backup` twin. Pass `KEY=` if your key
      is not `~/.ssh/id_ed25519`.
- [x] **teardown**: `task fleet-down PROVIDER=scaleway -- --yes`, then
      `python3 scripts/ops/purge-orphans/scaleway.py` reports nothing left
      → 62 destroyed, "no child cluster" from the fail-safe, project clean.

### Worth the extra spend, in priority order

The matrix (`docs/deployment-test-matrix.md` §C) ranks these as the highest-value
untested cases. Take as many as the budget allows, top down:

- [ ] **`SCW-mgmt-ha`** — 3 CP across 3 AZs. etcd across zones has never been
      applied. Highest value of the list.
- [ ] **`SCW-work-ha`** — the `workload` role on real cloud; only `management`
      has ever been exercised, and `workload` is what every spoke and every CAPI
      child reconciles.
- [ ] **`SCW-storage`** — `worker_storage` disks + LUKS2 `UserVolumeConfig`,
      never applied anywhere.
- [ ] **`task rolling-replace`** — proven on Scaleway before; re-run it since the
      Talos version moved.

## 5. Cloud — OVH

```bash
task preflight-quotas PROVIDER=ovh
task up ROLE=management PROVIDER=ovh
```

- [x] **`OVH-mgmt-ha`** — Octavia LB, floating IP, SNAT router → 3 CP + 3
      workers Ready, two Octavia LBs with their listeners and members, three
      floating IPs, the SNAT router and its interface. The Flux GitRepository
      resolved the pinned **tag** here too.
      First attempt died in 3 minutes on "Can not find requested image", after
      the network and bastion were billed: the tfvars pinned an image id the
      talos-image lane had replaced. `talos-image.sh` refuses on that mismatch
      now — it already knew both halves and merely suggested copying one over.
- [x] teardown **twice**: the Octavia LB orphaned in the 2026-07-30 teardown was
      silently reused by CAPO on the next deploy. `verify-provider-clean.py`
      covers it now; this is the run that proves the check, not the fix.
      → 79 destroyed, then "No changes, 0 destroyed". No LB survived.
- [x] `python3 scripts/ops/purge-orphans/ovh.py` clean on the first pass → yes
- [~] **the Talos upgrade does not complete on OVH.** Covered here because this
      is where it was attempted; see the backlog entry. `rolling-replace` is
      fixed (it replaced nothing: `-target` narrows a plan, it forces nothing,
      and an image change is only ForceNew on Scaleway) and the API stayed up
      throughout — 1300+ calls through the load balancer, zero failures. But the
      replaced node never rejoined, and the run was stopped rather than pushed
      further on a billed cluster. Do not claim a zero-downtime Talos upgrade
      for 1.1.0 on OVH.
- [ ] **`OVH-vip`** if budget allows — `k8s_lb_mode=vip` has never been applied
      on OVH, and Neutron's `allowed_address_pairs` is a different mechanism from
      Scaleway's anti-spoofing

## 6. Cloud — Outscale

```bash
task preflight-quotas PROVIDER=outscale -- --add-vms 2 --add-cores 4 --add-ram-gb 16
task up ROLE=management PROVIDER=outscale
```

- [~] **`OSC-mgmt-ha`** — the LB returns a **DNS name**, not an IP; that path is
      unique to this provider → the DNS name is confirmed
      (`…-k8s-lb-….lbu.outscale.com:6443`), but the topology was **3 CP + 1
      worker**, not 3+3: see the quota line below. etcd is still HA.
      Deploy and idempotency both clean — three applies, then "0 added, 0
      changed, 0 destroyed" on the second run.
- [x] the RAM quota (40 GB) is checked *before*, not discovered after: an HA
      management needs 44 GB, the overrun is tolerated at creation and then every
      further VM is silently refused
      → it refused, with that explanation. 3+3 of `tinav5.c2r7p2` is 42 GB and
      does not fit. Fix the quota or stop writing `OSC-mgmt-ha` as reachable.
- [ ] **`data.outscale_images`** resolves against the real API — the emulated lane
      exercises the `images[0]` shape but says nothing about *ordering*, and the
      module assumes most-recent-first
      → **not testable here.** The account holds exactly one Talos image, and
      building a second failed (see the backlog: the lane cannot replace an
      image while its AMI still references the snapshot). One image has no
      ordering to get wrong.
- [x] teardown + `purge-orphans/outscale.py` clean → 57 destroyed, account clean.
      Careful reading it: run straight after `fleet-down`, the purge listed five
      resources that were merely still being deleted — Outscale removes load
      balancers asynchronously. Re-run before concluding anything.

## 7. Upgrades — Kubernetes and Talos, on a cluster that has to stay up

§§1-6 prove a cluster can be built. They prove nothing about keeping one, which
is the half 1.0.0 shipped unverified. Run this on the reference provider at
minimum, on an HA topology, with a one-second probe so "no interruption" is a
number rather than an impression:

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

Point it at the endpoint in the kubeconfig, not at a tunnel to one node — a
tunnel measures that node, and the node you are upgrading is expected to go away.

**Check the version pair before moving either.** Talos supports a range of
Kubernetes versions, not all of them (1.13 covers 1.31-1.36). The starting pair,
the ending pair, and the intermediate state all have to sit inside it, because
one moves before the other. Nothing enforces this yet — see the backlog.

**Talos, in place.** `rolling-replace.sh --upgrade` calls `talosctl upgrade`,
which keeps the node's disk, identity and etcd membership, drains it itself, and
refuses a control-plane upgrade that would cost etcd its quorum. One node at a
time, health-gated between each. Re-runnable: a node already on the target
version is skipped.

```bash
task rolling-replace PROVIDER=scaleway KEY=~/.ssh/<key> -- --cp-only --upgrade
task rolling-replace PROVIDER=scaleway KEY=~/.ssh/<key> -- --workers-only --upgrade
```

**What to watch, beyond "it came back".** After each node: its name is unchanged
(`kubectl get nodes` — a `talos-xxxxx` entry means the hostname did not hold and
the next reboot will orphan another node object), the node count has not grown,
etcd still reports every member, and the probe's FAIL count has not moved much.

**Then plan again.** A clean upgrade leaves `tofu plan` at zero destroys. If it
wants to replace nodes, the boot image and the running version have disagreed —
that plan would take the cluster down, so stop and read
`modules/providers/provider-contract.md` § "Node image drift".

## 8. Cross-repo and CAPI, if you are exercising the optional layer

- [ ] a management with CAPI picked, then one child through `apps/clusters`
      (rename `example-scaleway.yaml.example` — **it does not build as shipped**,
      see `backlog.md`; fixing it is part of this test)
- [ ] `task edge-down CLUSTER=<name> -- --yes` then `task fleet-down` — in that
      order, always
- [ ] **`OP-failover`** — the DR path has never been proven. If you only do one
      thing from this section, restore something from a backup and write down
      what the runbook got wrong.

## 9. Release mechanics

Only once everything above is green.

- [ ] `docs/deployment-test-matrix.md` updated with what you actually ran —
      including the ones that failed
- [ ] `docs/backlog.md` — drop what is now done, add what this shook out
- [ ] **`OpenAether-apps` tagged `1.0.1` first**, then `OpenAether-infra`
- [ ] a GitHub Release on each (there are none today, on any tag)
- [ ] `git describe --tags` clean on both
- [ ] the twelve `envs/*.tfvars.example` still pin `refs/tags/1.0.1`

## 10. Before communicating

- [ ] clone the repo **as a stranger would** — no local state, no `.env.sh` —
      and do §1 and §2 one more time
- [ ] read `README.md` top to bottom as someone who has never seen it: the
      disclaimers (Proxmox never applied, the emulator proving nothing about a
      real deploy, Grafana SSO pending) are the reason a knowledgeable reader
      will trust the rest. Do not soften them.
- [ ] decide what the announcement claims, and check each claim against the
      matrix. "Validated on three providers" is true of `management`; it is not
      true of `workload`, of HA multi-AZ, or of Proxmox.

---

## What this checklist will not tell you

Proxmox. `PMX-*` is code-complete, unit-tested, and has **never touched real
hardware** — no amount of cloud testing changes that, and the README says so in
three places. Keep it saying so.
