# Release checklist — 0.1.0

English only, like `backlog.md`: rewritten each release, and two copies would drift.

What to run before tagging 0.1.0 and telling anyone about it. Ordered by what
fails cheapest. **Stop at the first red** — every later step assumes the earlier
ones held.

Record the result next to each line as you go. A line with no result is a line
nobody ran, and that is the answer this checklist exists to make visible. The
ticks below carry the evidence 0.1.0 rests on; everything unticked is yours to
run and to write down.

0.1.0 is infrastructure only: one Talos cluster, Cilium as the whole platform,
Flux off (`deploy_flux = false`), no applications and no CAPI. Anything about
Flux, `OpenAether-apps` or a child cluster belongs to a later release and is not
a gate on this one. Three clouds are proven and no bare metal is — the
checklist says on what, and so must the announcement.

---

## 1. Clean-machine bootstrap (the first five minutes)

The point is a **fresh clone in a fresh directory**. Your working tree has files
a clone does not — that is exactly how the CNI defect survived.

```bash
cd $(mktemp -d)
git clone https://github.com/dis-bzh/OpenAether-infra
cd OpenAether-infra && git checkout <the 0.1.0 candidate>
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

- [ ] `setup.sh` completes and installs **helm** (`command -v helm`)
- [ ] it warns if `nc` is absent, and does not claim to install it
- [ ] every command the README quick start names exists (`task --list`)
- [ ] `task preflight` green — lint, render, validate, `tofu test` and the script
      harnesses. That is 350 offline assertions across 14 harnesses, every one
      mutation-tested; a count that has silently shrunk is a red line, not a pass.
- [ ] no bucket is orphaned by a rename in this release. `…-talos-staging` became
      `…-talos-import` (2026-08-20): the old one still holds every QCOW2 it was
      ever given, on every cloud built from. `task purge-orphans PROVIDER=…` lists
      it; emptying and deleting it is by hand.

## 2. Local Docker — the credential-free rung

Still in the **fresh clone**, no `.env.sh`, no credentials in the shell.

```bash
task local-up
task local-status
task local-test
task local-down
```

- [ ] `local-up` renders `cilium-local.yaml` itself when the manifest is absent
- [ ] **Cilium is actually running** — `kubectl -n kube-system get pods -l k8s-app=cilium`.
      A cluster whose pods are Pending with no CNI still looks like a successful apply.
- [ ] `local-status` prints etcd members
- [ ] `local-test` reaches its green banner **and** its checks are fatal.
      Do NOT test this by stopping a container: the script re-applies before it
      checks, so tofu simply recreates it. Break something the apply will not
      put back — `kubectl -n kube-system delete daemonset cilium`.
- [ ] `local-down` leaves no container, volume or network behind. Diff against a
      snapshot taken before `local-up`; a bare `docker ps -a` on a workstation
      lists every other project you have ever run.
- [ ] a second `local-up`, with the manifest already rendered, does not re-render it

## 3. Emulated cloud — no account, real provider binaries

The lane is pinned to Feint 0.9.0, running against the same Scaleway provider
version the clusters run.

```bash
task feint-up
task feint-test                        # both providers, plan + CRUD
task feint-record PROVIDER=scaleway
task feint-record PROVIDER=outscale
task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com   # must REFUSE
task feint-down
```

- [ ] both providers green on plan and on the apply/destroy cycle, each with an
      empty re-plan and a destroy confirmed against the API
- [ ] the ranking still shows the four known operations and no new one —
      3 on Scaleway (`ipam BookIP`, `lb ips`, `vpc-gw ips`), 1 on Outscale
      (`CreateLoadBalancer`). A fifth means a module started calling something
      nothing serves.
- [ ] the guard refuses a non-loopback endpoint — check it both ways, as a Task
      variable and as an environment variable. A Task variable is not an
      environment variable, and this test once passed without testing anything.

## 4. Cloud — Scaleway first, it is the reference

Use a **throwaway project**, not one holding anything real.

```bash
source .env.sh
cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars{.example,}
$EDITOR infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/your-key
```

`preflight-quotas` has no Scaleway backend — it takes `ovh` or `outscale` only.
`task cluster-up` refuses before spending if the env file, the SSH key, an S3
credential pair or the passphrase is missing.

- [x] **deploy from an empty account** → 2026-08-19: 8 min 50 for 72 resources.
- [x] **`task cluster-verify`** → 11/11.
- [x] **idempotency is three assertions, not one**: an empty plan, the *same*
      nodes (name and `creationTimestamp`), and a kubeconfig that still reaches
      the apiserver → 3/3. Two of the three can pass while the cluster was
      silently rebuilt, which is why one of them is not enough.
- [x] **upgrades, end to end** — Kubernetes v1.36.2 → v1.36.3, then Talos v1.13.7
      → v1.13.8 in place, confirmed on 6/6 nodes by each node's own Talos API
      (`stage=running`, fallback dropped) rather than by the tool that performed
      the upgrade. Longest apiserver outage **5 s**, 16 failed probes out of 575.
- [x] **the replica really is elsewhere** — an encrypted tfstate in a `-backup`
      store at Outscale while the cluster ran on Scaleway, opened with THAT
      cloud's keys. S3 credentials are namespaced by the cloud that holds the
      bucket, not by the cluster.
- [ ] `task etcd-snapshot PROVIDER=scaleway` writes to both buckets. Pass `KEY=`
      if your key is not `~/.ssh/id_ed25519`.
- [ ] **teardown**, two commands and then the provider's own answer:
      ```bash
      task cluster-down PROVIDER=scaleway
      task cluster-down PROVIDER=scaleway PLAN=destroy-management-scaleway.tfplan APPROVE=auto
      python3 scripts/ops/purge-orphans/scaleway.py
      ```
      Record the counts. The 2026-08-19 deploy started from an empty account, so
      what preceded it left nothing — that is a fact about a previous run, not a
      result for yours.

### Worth the extra spend, in priority order

The matrix (`docs/deployment-test-matrix.md` §C) ranks these as the highest-value
untested cases. Take as many as the budget allows, top down:

- [ ] **`SCW-work-ha`** — the `workload` role on real cloud; only `management`
      has ever been exercised.
- [ ] **`SCW-storage`** — `worker_storage` disks + LUKS2 `UserVolumeConfig`,
      never applied anywhere.
- [ ] **`task cluster-roll`** — re-run it since the Talos version moved.

## 5. Cloud — OVH

```bash
task preflight-quotas PROVIDER=ovh
task cluster-up ROLE=management PROVIDER=ovh
```

- [x] **the same five pillars, the same day** — deploy, `cluster-verify` 11/11,
      idempotency 3/3, and both upgrades to the same versions as Scaleway,
      2026-08-19.
- [x] **the interruption is a number** → longest outage **7 s**, 9-10 failed
      probes out of ~540. Worse than the 1 s this provider once recorded; quote
      this one.
- [ ] teardown **twice**: an Octavia LB orphaned by one teardown was silently
      reused by the next deploy. `verify-provider-clean.py` covers it now — this
      is the run that proves the check, not the fix.
- [ ] `python3 scripts/ops/purge-orphans/ovh.py` clean on the first pass
- [ ] **`OVH-vip`** if budget allows — `k8s_lb_mode=vip` has never been applied
      on OVH, and Neutron's `allowed_address_pairs` is a different mechanism from
      Scaleway's anti-spoofing

## 6. Cloud — Outscale

```bash
task preflight-quotas PROVIDER=outscale
task cluster-up ROLE=management PROVIDER=outscale
```

Deploy into a **fresh Net**. What blocked this provider was a timeout inside
Outscale's own LBU service: it stops waiting after 10 s while the VM the load
balancer needs takes about 10.7, so the workflow fails, the internal resources
are created anyway and the LBU stays in `provisioning` for ever. Support request
**399530** carried that diagnosis and is **closed**; the instruction that came
with it is do not create another LBU in that Net, use a new one.

Do not tick anything here from an earlier cycle — the 2026-08-13 run does not
count, its Talos upgrade reverted on the next reboot.

- [x] **the same five pillars as Scaleway and OVH, measured the same way** →
      2026-08-20: deploy — 51 resources, then 17 — `cluster-verify` 11/11,
      idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos v1.13.7 → v1.13.8
      confirmed on 6/6 nodes by each node's own Talos API (`stage=running`,
      fallback dropped). The new load balancer reached `active` with 3 backends.
- [x] **the interruption is a number** → longest outage **8 s**, the worst of the
      three clouds and worse than the 1 s this provider once recorded. Quote this
      one.
- [ ] teardown, then `python3 scripts/ops/purge-orphans/outscale.py` clean

**Two things stay true here and belong in the announcement.** One Net created
before the fix still refuses deletion, on a dependency no read returns — only
Outscale can clear it, and a second support request is open for it; it is not
your leak, and it must not hide one. And this object store does not honour
conditional writes: measured with the same client that got a refusal from
Scaleway and OVH, it accepts the second one — so `use_lockfile` is on for those
two and deliberately **off** here, where it would claim a state lock and hold
nothing. Nothing stops two concurrent runs against an Outscale cluster's state.

## 7. Upgrades — Kubernetes and Talos, on a cluster that has to stay up

§§1-6 prove a cluster can be built. They prove nothing about keeping one, which
is the half every 1.x tag shipped unverified.

The procedure itself is [`upgrade.md`](upgrade.md) — it is not release-specific
and does not belong here twice. What a *release* adds to it:

- [x] the one-second probe up throughout, and the claim made as a number: the
      LONGEST consecutive run of failed `/readyz` samples, not the total.
      5 s on Scaleway, 7 s on OVH, 8 s on Outscale — every one of them worse than
      this project's own records (3 s, 1 s and 1 s), and all three are what the
      announcement quotes. "No interruption" is not measurable.
      A fix shipped 2026-08-20 — the roll takes the etcd leader LAST and hands
      leadership over with `talosctl etcd forfeit-leadership` instead of letting
      its disappearance force an election — but whether that is what was costing
      the seconds has not been measured. Do not present it as the explanation.
- [x] run on **three clouds**, not only the reference one: the known first-apply
      failure (upstream #352) reproduces on OVH and not on Scaleway.
- [ ] every node upgraded **in place**, none replaced, every one back under its
      own name — and the running SCHEMATIC compared, not just the version tag
- [ ] `task infra-plan ... STRICT=1` exits 0 afterwards
- [ ] whatever it shook out is in `backlog.md` before the tag, including what you
      chose not to fix

`scripts/dev/cluster-upgrade.sh` does all of the above unattended and does not
retry the failing apply, on purpose.

## 8. Release mechanics

Only once everything above is green.

- [ ] `docs/deployment-test-matrix.md` updated with what you actually ran —
      including the ones that failed
- [ ] `docs/backlog.md` — drop what is now done, add what this shook out
- [ ] `CHANGELOG.md` names what 0.1.0 claims **and** what it does not
- [ ] a GitHub Release, with notes that name the open items
- [ ] `git describe --tags` clean
- [ ] the `envs/*.tfvars.example` carry `git_ref = "refs/heads/main"` — infra
      pins no `OpenAether-apps` tag, so there is no ordering constraint between
      the two repositories and no matching-version rule to honour

## 9. Before communicating

- [ ] clone the repo **as a stranger would** — no local state, no `.env.sh` —
      and do §1 and §2 one more time
- [ ] read `README.md` top to bottom as someone who has never seen it: the
      disclaimers (Proxmox never applied on hardware, the undeletable Outscale
      Net, the emulator proving nothing about a real deploy, no applications
      above Cilium) are the reason a knowledgeable reader will trust the rest.
      Do not soften them.
- [ ] decide what the announcement claims, and check each claim against the
      matrix. "Validated on three clouds" holds — Scaleway, OVH and Outscale.
      "Validated on three providers" does not: Proxmox has never touched real
      hardware, and nothing above Cilium is deployed at all.

---

## What this checklist will not tell you

Proxmox. `PMX-*` is code-complete, unit-tested, and has **never touched real
hardware** — no amount of cloud testing changes that, and the README says so
where it lists the providers. Keep it saying so.
