# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

Keep it short: one entry = the defect, its cost, what to do. Detail lives in the
code comment, the runbook or the commit message, referenced by path.

⚠️ This file drifted into a lab notebook (215 lines, one entry at 32) and was cut
back on 2026-07-29. If an entry starts explaining what was ruled out, the
explanation belongs in the commit that ruled it out.

## Where we stand

Alerting exists and is proven end to end: 19 rules, a real alert delivered to
Slack from a Scaleway cluster, and a `Watchdog` whose silence is the signal.
etcd, Cilium, Flux and cert-manager are scraped.

2026-07-30: the full 1.0.0 phased rollout ran end to end — a real 3-provider
fleet (management/Scaleway + edge-2/OVH + edge-3/Outscale, both edges
gitception-injected, `workload` profile autonomous), a real Talos/K8s rolling
upgrade proven zero-downtime on edge-2 (after fixing a real surge-FIP gap),
and a full `task fleet-down` teardown. CI hardened (SHA-pinned actions/hooks,
branch rulesets, object-collision gate) on both repos. Fleet is torn down;
the `1.0.0` tag itself is deliberately deferred to a later session.

2026-07-31: the two gaps the 2026-07-30 teardown had exposed are fixed and
validated live, not just reasoned about — `task infra` no longer forces
`talos_bootstrap=false` on an already-bootstrapped cluster (re-ran `task up`
twice on a fresh Scaleway management: 0 changes on the second pass, node ages
unchanged, kubeconfig intact), and `edge-down.sh` now re-checks the provider
directly after the Kubernetes-level cascade instead of trusting it (new
`scripts/ops/verify-provider-clean.py`). Proving that second fix live
surfaced a THIRD real bug on the first try: an Octavia load balancer orphaned
by the 2026-07-30 OVH teardown was silently reused by CAPO on the next
`edge-2` deploy and broke it (stale VIP port, 404). Fixed live (scoped delete,
`scripts/ops/delete-openstack-resource.py`) and now a permanent check in
`verify-provider-clean.py`. Both fixes then proved on a full real cycle: fresh
management → real OVH edge-2 deploy → `edge-down.sh` teardown (provider
verified clean on the first pass) → full `fleet-down` (edge-3, never
provisioned — blocked cleanly on missing Outscale credentials, no spend) →
all 3 providers independently re-verified clean. Fleet is torn down again;
`1.0.0` tag still pending.

**Idempotency bilan (Phase 4, 2026-07-30):** CAPI provisioning, gitception
injection and each child's own Flux reconciliation are genuinely automatic —
no operator step once credentials exist. What is NOT: per-provider CAPI
credentials/keypairs (`kubectl create secret`, by hand, no `task` target);
OVH's floating IP (scripted allocation, but the address is hand-copied into
git); and OpenBao seeding (`bao kv put`, entirely manual per cluster, by
design — secrets don't belong in git — but with real room for the ordering
bug below). `task up`/`bootstrap-phase2` re-run safety against an
already-bootstrapped cluster is fixed as of 2026-07-31, see above.

## Open — work we can do

- [ ] **`clusterctl-inventory` brick is dead on an operator-only CAPI install.**
      Found live 2026-07-30 (Scaleway management, full profile): the classic
      `Provider` CRD (`clusterctl.cluster.x-k8s.io/v1alpha3`) it writes to
      never gets installed — `cluster-api-operator` only installs its own
      `operator.cluster.x-k8s.io` CRDs (CoreProvider, InfrastructureProvider…),
      not the old imperative `clusterctl init` inventory. Non-blocking (no
      other Kustomization depends on it, confirmed) but permanently
      `ReconciliationFailed`. Either find how to get the classic CRD installed
      alongside the operator, or drop the brick if `clusterctl move` support
      isn't actually needed.

- [ ] **Log in to a UI through the gateway.** The transport is DONE (2026-07-29,
      Scaleway): `https://longhorn.openaether.local` answers **HTTP 200** through
      the gateway, served with `CN=openaether.local` issued by our own
      intermediate. What is left is only the Grafana↔Zitadel claim form, which
      needs `grafana-oidc` seeded and a human browser.
      Two traps found doing it: import the signed intermediate ALONE (the root
      too and OpenBao picks an issuer with no private key), and re-signing the
      same subject needs `unique_subject = no` in `index.txt.attr` — the `.cnf`
      is not what controls it.
      ⚠️ The LB-IPAM VIP is not reachable from the bastion; reach the gateway by
      port-forward or from inside the cluster.

- [~] **Flux has no per-object Ready signal.** `gotk_reconcile_condition` is gone
      in Flux 2.8; `FluxReconciliationStalled` covers "stopped", not "failing".
      The kube-state-metrics `customResourceState` route produced a series
      exactly once and could not be reproduced (elimination list in `9ac133d`).
      Asked upstream 2026-07-29: kubernetes/kube-state-metrics#3052. Waiting —
      do not spend more time guessing at config.

- [ ] **`CreateTags` says a resource the emulator just created does not exist.**
      `taggable` (`internal/providers/outscale/tags.go`) knows four prefixes —
      `vpc-`, `subnet-`, `i-`, `key-` — against sixteen the pack mints, so ten
      taggable kinds answer `5063 InvalidResource` on ids it returns from its own
      `Read*`. Not cosmetic: the provider fails the apply (`Unable to create
      tags`), the resource is tainted, and the next apply fails identically — the
      configuration cannot converge. Reproduced on 0.7.0 with a two-resource
      OpenTofu config. Our fixture works around it by leaving the internet
      service and route tables untagged. Reported as `stephrobert/feint#99`.

- [ ] **A full emulated apply of the cluster root needs two routes, and two
      decisions reversed.** Measured on 0.6.0 and again on 0.7.0, identical both
      times (`task feint-record`). Genuinely missing: Scaleway LB (SW-5 `#17`)
      and public gateway (SW-6 `#18`). Declined *with a stated reason*, which is
      a different conversation: `ipam BookIP` (SW-4 `#11`) because addresses come
      from the subnet plan rather than a client reservation, and Outscale
      `CreateLoadBalancer` (OSC-5 `#16`) because the emulator has no data plane
      to hand a working DNS name for. Arguing either means arguing a real client
      is blocked, not that a metric is short. Until then the real root stops at
      `plan` and the CRUD cycle runs on `infrastructure/opentofu-feint`.

- [ ] **Compare our providers' answers with a real cloud, using `feint shapes`
      (0.7.0).** `task feint-record` answers "what do we call that no pack
      serves"; this answers "does the shape match", which is the half a proxy
      cannot reach — a client signs the host it was configured with, so a real
      cloud behind a reverse proxy answers 401. 0.7.0 solved it with a
      per-provider signer rather than the DNS/TLS interception their `#76`
      proposed. Recording needs a real account, so it rides on the next
      real-cloud session; `feint shapes --check` then compares offline with no
      credential.

- [ ] **Six `envs/*.tfvars.example` cannot be applied as written.** They set
      `bastion_ssh_keys = { <provider> = "ssh-ed25519 …" }`, a bare string, where
      the variable is `map(list(string))`: `element "<provider>": list of string
      required, but have string`. Confirmed by running it, 2026-08-08. Affects
      failover/workload × scaleway/ovh/outscale, plus the commented proxmox
      lines; only `management-scaleway` has the list form. One-token fix per
      file, left out of the emulated-cloud change to keep that diff readable.

- [ ] **`talos-image` root is outside the emulated lane.** It stages images
      through object storage, which Feint does not emulate (the Scaleway
      provider hardcodes the S3 endpoint in code — not redirectable).

- [ ] **Outscale provider 1.x deprecates the top-level `region`.** The real path
      still sets it, so every real Outscale command warns; only the emulated
      path uses the `api {}` block. Moving real runs onto the block means
      building `https://api.<region>.outscale.com/api/v1` ourselves, i.e.
      hardcoding their DNS — decide which is worse before changing it.

## Blocked on the world, not on us

Not work. Conditions. Do not re-investigate them from a desk.

- [ ] **Proxmox never applied for real** — needs the hardware. Plus Ansible host
      hardening, documented but absent from the repo.

- [ ] **OVH: a node can stay `ACTIVE` while dead.** `vp_reset` is virtio-pci's
      reset; `device_shutdown()` runs on every reboot path, so no Talos-side
      lever avoids it — only a hypervisor reset, which the recovery already
      prescribes. Detection is covered by `NodeUnreachable`. The root cause
      needs the incident to recur WITH the serial console attached.

- [ ] **Outscale RAM quota (40 GB) vs an HA management (44 GB).** The overrun is
      tolerated at creation, then every further VM is refused silently.
      `task preflight-quotas` catches it; raising the quota is your call.

- [~] **`talos_cluster_health` times out on healthy clusters.** OVH and Outscale
      only — Scaleway passed a full apply on 2026-07-29, so the entry's old
      "generic defect" claim was wrong. Damage is contained (`skip_health_check`,
      and the kubeconfig no longer depends on it). Upstream 0.11.0 is still the
      newest stable. Filing needs evidence from an OVH or Outscale run:
      `TF_LOG=DEBUG` on the failing read, `talosctl health` at the same moment,
      and one run with `skip_kubernetes_checks = true`.

## Traps worth remembering

One line each; the detail lives in the referenced file.

- **Flux substitution applies to a whole Kustomization render** — it blanks bare
  shell variables. Isolate `substituteFrom` in a brick with no script
  (`22a-backup-identity.yaml`).
- **An operator and its own CRs need two Kustomizations** — a bundle with both is
  rejected at dry-run while the CRDs do not exist yet.
- **`toServices: kubernetes` gets dropped** — the Service DNATs 443→6443 and
  Cilium enforces on the post-DNAT port. Use `toEntities: kube-apiserver`.
- **A Kustomize `namespace:` overrides every resource**, including those of a
  referenced base — that is why `vault-ca` is a separate brick.
- **Validating a file is not validating the brick**: apply the directory
  (`kubectl apply -k`), never an isolated file.
- **`clusterctl move --dry-run` does not check providers** — it passes, and the
  real move fails.
- **Before translating a string, check that no code compares it** — `pick.py`
  identified its profiles by their French header.
- **Never conclude from truncated output** — a `| tail` hid the servers that
  `purge-orphans` lists first, making a populated account look clean.
- **An empty server list is not an empty account** — 7 Scaleway block volumes
  billed for three days behind a clean-looking instance list. Check volumes.
- **`clusterctl init` does not install ORC** — CAPO v0.14 needs it, and without
  it the manager exits: network/LB/FIPs get created but no server ever does.
  See `capi-bootstrap.md`.
- **Outscale `region` ≠ subregion** — `eu-west-2a` in the credentials secret
  builds an API host that does not resolve. Use `eu-west-2`.
- **A generated artifact drifts silently** — hence `task render-check` and
  `pick.py --check`. Prefer guardrails that compare over ones that assume.
- **`up == 0` only catches NODE-discovered targets** — a pod target vanishes
  from discovery instead of reporting 0, and an absent series matches nothing.
  Full reasoning in the `CiliumAgentMissing` rule comment.
- **A rule on a metric nobody produces never fires, and never says so** —
  `task check-alerts` asks a live cluster which referenced metrics have no data.
- **`repeat_interval` must be strictly greater than `group_interval`** —
  Alertmanager sent one webhook in 11 min when both were 5m, which would trip a
  dead-man's switch on a healthy cluster.
- **A failed Job is permanent under Flux** — it re-applies the same spec and
  never restarts a finished Job. A bootstrap Job must WAIT for its dependency,
  not exit; `openbao-vault-bootstrap` left a cluster with no KV and no PKI while
  its Kustomization reported Ready.
- **A `VMRule` with no `VMAlert` is inert** — stored, never evaluated, and no
  component reports the gap.
- **kube-state-metrics needs `honorLabels: true`** — otherwise its labels become
  `exported_*` and every rule selecting on `namespace`/`pod` matches nothing.
- **A component's metrics port is often its service port** — vmselect serves
  queries AND /metrics on 8481. Removing a CNP rule as "query-only" took the
  self-scrape down with it. Check `up == 0` after touching an observability CNP.
- **A batch translation leaves half-translated blocks** — a French line between
  two English ones reads as finished and no linter catches it. Sweep, don't trust.
- **A CNP with no egress-to-S3 rule doesn't fail fast, it hangs** — CNPG's own
  instance pods (not just the separate `cnpg-dump` job) need it for
  `barmanObjectStore` archive/restore. A single-instance cluster never
  notices; a replica JOIN calling `restore_command` blocks forever instead of
  erroring — found live on edge-3 2026-07-30, apps repo
  `cnpg/networkpolicy-db-restricted.yaml`.
- **A resource-count driven by a phase variable is not idempotent** — gating
  `module.talos`'s `control_plane_count`/`worker_count` on `var.talos_bootstrap`
  meant every re-run of `task infra` (talos_bootstrap=false, part of `task up`)
  zeroed them and dropped `talos_machine_bootstrap` from state, which then got
  RECREATED by `bootstrap-phase2` — re-sending the bootstrap RPC to a live
  etcd. Fixed by reading `tofu state list` first (`Taskfile.yml`'s `infra`
  task) instead of always forcing the phase-1 value.
- **CAPO reuses an Octavia LB by NAME on the next deploy — a leftover isn't
  just cruft, it silently breaks the redeploy.** A `kubeapi` LB orphaned by a
  prior `edge-down` (its VIP port's network long gone) got picked up by CAPO
  on the next `edge-2` apply instead of a fresh one being created; the FIP↔port
  association then 404s forever with no error surfaced to Flux. `edge-down.sh`
  now re-verifies the provider directly after the Kubernetes-level cascade
  (`verify-provider-clean.py`, checks LBs too) instead of trusting it blindly.
- **Seed OpenBao app-DB secrets BEFORE the CNPG cluster's first `initdb`** —
  seeding late doesn't stop the Cluster going Ready (bootstrap self-generates
  a placeholder), it just leaves the live Postgres role's password out of
  sync with what the Secret (and hence the app) now has. Needs `ALTER ROLE
  ... WITH PASSWORD` to realign, or a CNPG `managed.roles` sync so future
  secret rotations don't repeat this.
