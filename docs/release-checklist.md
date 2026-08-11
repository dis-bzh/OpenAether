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

- [ ] `setup.sh` completes and installs **helm** (`command -v helm`)
- [ ] it warns if `nc` is absent, and does not claim to install it
- [ ] every command the README quick start names exists (`task --list`)

## 2. Local Docker — the credential-free rung

Still in the **fresh clone**, no `.env.sh`, no credentials in the shell.

```bash
task local-up
task local-status
task local-test
task local-down
```

- [ ] `local-up` renders `cilium-local.yaml` itself (watch for the render step)
- [ ] **Cilium is actually running** — `kubectl -n kube-system get pods -l k8s-app=cilium`.
      This is the one that was broken. A cluster whose pods are Pending with no
      CNI still looks like a successful apply.
- [ ] `local-status` prints etcd members — it dialled the wrong port until now
- [ ] `local-test` reaches its green banner **and** its etcd/health checks are
      fatal now: make one fail on purpose (stop a container mid-run) and confirm
      the script exits non-zero
- [ ] `local-down` leaves no container, volume or network behind (`docker ps -a`,
      `docker volume ls`)

Then repeat `local-up` **with the manifest already rendered** — the normal case
for you — and confirm it does not re-render needlessly.

## 3. Emulated cloud — no account, real provider binaries

```bash
task feint-up
task feint-test                        # both providers, plan + CRUD
task feint-record PROVIDER=scaleway
task feint-record PROVIDER=outscale
task feint-plan PROVIDER=scaleway FEINT_ENDPOINT=https://api.scaleway.com   # must REFUSE
task feint-down
```

- [ ] both providers green on plan and on the apply/destroy cycle
- [ ] the ranking still shows the four known operations and no new one
- [ ] the guard refuses a non-loopback endpoint:
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

- [ ] **`SCW-mgmt-nonha`** — 1 CP + 1 worker, the cheapest real path
- [ ] the apps `GitRepository` resolves the ref you pinned:
      `kubectl -n flux-system get gitrepository openaether -o yaml | grep -A3 'ref:'`
      → this is the **`ref.name` change**, and the first time it meets Flux
- [ ] every Flux Kustomization Ready: `flux get kustomizations -A`
- [ ] **no Longhorn HTTPRoute**: `kubectl -n longhorn-system get httproute`
      → should be empty. Then add the route back by hand and confirm the UI is
      reachable, so you know the opt-in path still works before you document it.
- [ ] **idempotency**: `task up` a second time → 0 changes, node ages unchanged,
      kubeconfig still valid
- [ ] `task etcd-snapshot PROVIDER=scaleway` writes to both buckets
- [ ] **teardown**: `task fleet-down PROVIDER=scaleway -- --yes`, then
      `python3 scripts/ops/purge-orphans/scaleway.py` reports nothing left

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

- [ ] **`OVH-mgmt-ha`** — Octavia LB, floating IP, SNAT router
- [ ] teardown **twice**: the Octavia LB orphaned in the 2026-07-30 teardown was
      silently reused by CAPO on the next deploy. `verify-provider-clean.py`
      covers it now; this is the run that proves the check, not the fix.
- [ ] `python3 scripts/ops/purge-orphans/ovh.py` clean on the first pass
- [ ] **`OVH-vip`** if budget allows — `k8s_lb_mode=vip` has never been applied
      on OVH, and Neutron's `allowed_address_pairs` is a different mechanism from
      Scaleway's anti-spoofing

## 6. Cloud — Outscale

```bash
task preflight-quotas PROVIDER=outscale -- --add-vms 2 --add-cores 4 --add-ram-gb 16
task up ROLE=management PROVIDER=outscale
```

- [ ] **`OSC-mgmt-ha`** — the LB returns a **DNS name**, not an IP; that path is
      unique to this provider
- [ ] the RAM quota (40 GB) is checked *before*, not discovered after: an HA
      management needs 44 GB, the overrun is tolerated at creation and then every
      further VM is silently refused
- [ ] **`data.outscale_images`** resolves against the real API — the emulated lane
      exercises the `images[0]` shape but says nothing about *ordering*, and the
      module assumes most-recent-first
- [ ] teardown + `purge-orphans/outscale.py` clean

## 7. Cross-repo and CAPI, if you are exercising the optional layer

- [ ] a management with CAPI picked, then one child through `apps/clusters`
      (rename `example-scaleway.yaml.example` — **it does not build as shipped**,
      see `backlog.md`; fixing it is part of this test)
- [ ] `task edge-down CLUSTER=<name> -- --yes` then `task fleet-down` — in that
      order, always
- [ ] **`OP-failover`** — the DR path has never been proven. If you only do one
      thing from this section, restore something from a backup and write down
      what the runbook got wrong.

## 8. Release mechanics

Only once everything above is green.

- [ ] `docs/deployment-test-matrix.md` updated with what you actually ran —
      including the ones that failed
- [ ] `docs/backlog.md` — drop what is now done, add what this shook out
- [ ] **`OpenAether-apps` tagged `1.0.1` first**, then `OpenAether-infra`
- [ ] a GitHub Release on each (there are none today, on any tag)
- [ ] `git describe --tags` clean on both
- [ ] the twelve `envs/*.tfvars.example` still pin `refs/tags/1.0.1`

## 9. Before communicating

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
