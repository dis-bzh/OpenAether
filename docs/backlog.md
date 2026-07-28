# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

Keep it short: one entry = the defect, its cost, what to do. Detail lives in the
code comment or the runbook, referenced by path.

## Where we stand (2026-07-28)

✅ **Nothing running — accounts verified empty**, including block volumes (see
below). S3 buckets and Talos images deliberately kept.

**`providerID` is fixed on ALL THREE providers** (2026-07-28, validated on real
cloud): cluster templates put the kubelet in `cloud-provider=external` + enable
`kubernetesTalosAPIAccess`, and every child runs the Talos CCM. Talos emits each
infra provider's own format verbatim — `scaleway://instance/<zone>/<uuid>`,
`openstack:///<uuid>`, `aws:///<subregion>/<id>` — so **no transformation is
needed anywhere**. Machines reach `Running` with `nodeRef` resolved and
MachineHealthCheck reports healthy on Scaleway, OVH and Outscale. It had never
worked before.

**kyverno background-controller requalified**: it runs (0 restart) and produces
reports. The old entry looked for `ClusterPolicyReport`s, but all five policies
match `Pod`, a namespaced kind — Kyverno therefore emits `PolicyReport`s. 22
reports, 104 evaluations, all five policies reporting. No defect.

Validated on real cloud this session, then torn down: a 5-cluster fleet across
2 providers (management OVH + edge-1 SCW + edge-2 OVH, and mgmt-capi SCW born
from CAPI, itself driving edge-capi). Two firsts: gitception works
cross-provider **in both directions**, and a **CAPI-bootstrapped management
manages itself** after the throwaway cluster is destroyed (`capi-bootstrap.md`).

## Open

- [ ] **Browser SSO login (Grafana ↔ Zitadel).** Everything else is done; only
      the claim form remains to confirm. Needs a live cluster.
      Protocol: `admin-access.md` § 8 (browser tests).

- [ ] **Gateway → UI path.** Untestable until the PKI intermediate is signed
      offline (`admin-access.md` § 2). The code is already hardened.

- [ ] **OVH: a node can stay `ACTIVE` on the hypervisor while dead.** Talos
      called `reboot()` and the kernel hung in `device_shutdown` / `vp_reset`.
      Recovery: `HARD` reboot through the Nova API. Open: why did Talos reboot?
      Method: when `talosctl` resets on one node only, go to the serial console.

- [ ] **Outscale RAM quota (40 GB) saturated by an HA management (44 GB).**
      The overrun is tolerated at creation, then every further VM is refused
      with no error in the CAPI CR. HA management and a child are mutually
      exclusive on this account. `task preflight-quotas` catches it; raising the
      quota is an operator decision.

- [ ] **Proxmox: never applied for real.** Plus Ansible host hardening, which is
      documented but absent from the repo.

- [~] **`talos_cluster_health` times out on healthy clusters** (OVH, Outscale).
      The damage is fixed — `talos_cluster_kubeconfig` no longer depends on it,
      so an expiry keeps the signal without losing kubeconfig/talosconfig.
      Workaround: `skip_health_check`. Upstream: the provider's 0.12.x line has
      no stable release; either wait or open the issue with both traces.

- [ ] **Keep trimming.** Done 2026-07-28: docs 2315 → 987 lines. Remaining: 48
      comment blocks of 15+ lines (860 lines total) — mostly file headers, which
      are legitimate; cut them only where they narrate an incident instead of
      stating the why. See `CLAUDE.md` § Concision et refacto.

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
- **An empty server list is not an empty account** — Scaleway kept 7 orphaned
  block volumes billing for three days behind a clean-looking instance list.
  `purge-orphans/scaleway.py` now covers volumes.
- **`clusterctl init` does not install ORC** — CAPO v0.14 needs it, and without
  it the manager exits: network/LB/FIPs get created but no server ever does.
  See `capi-bootstrap.md`.
- **Outscale `region` ≠ subregion** — `eu-west-2a` in the credentials secret
  builds an API host that does not resolve. Use `eu-west-2`.
- **A generated artifact drifts silently** — hence `task render-check` and
  `pick.py --check`. Prefer guardrails that compare over ones that assume.
