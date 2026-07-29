# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

Keep it short: one entry = the defect, its cost, what to do. Detail lives in the
code comment or the runbook, referenced by path.

## Where we stand (2026-07-29)

**Alerting now exists.** The platform had three `VMRule`s and no evaluator, so
none of them could ever fire — the backup safety net was decorative. Added
VMAlert + VMAlertmanager and six cluster-health rules (nodes, pods, volumes,
plus an `absent()` guard on kube-state-metrics itself). Validated on the local
cluster: 9 rules loaded, 0 evaluation errors, a real `BackupJobFailed` goes
`pending` against a genuinely failed Job, and a synthetic alert reaches
Alertmanager. Three defects fell out of that run — see the traps below.

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

- [ ] **Reach a UI through the gateway.** The TLS half is DONE (2026-07-29,
      Scaleway): a throwaway root CA signed the intermediate with `openssl ca`,
      `bao write pki/intermediate/set-signed` imported it, `openaether-tls` went
      Ready and the gateway's **https listener reports Programmed=True**. What
      was never exercised is the hop after that — an actual HTTP request through
      the gateway to a UI — because it needs a browser and a resolvable name.
      Pairs with the SSO test above: one deployment closes both.
      ⚠️ Import the signed intermediate ALONE. Concatenating the root makes
      OpenBao import two issuers, and cert-manager then fails on whichever has
      no private key.

- [ ] **OVH: a node can stay `ACTIVE` on the hypervisor while dead.** Talos
      called `reboot()` and the kernel hung in `device_shutdown` / `vp_reset`.
      Recovery: `HARD` reboot through the Nova API.
      Investigated 2026-07-29, and the conclusion is narrower than hoped.
      `vp_reset` is virtio-pci's reset: the guest waits on a device the host is
      no longer servicing. There is no Talos-side switch that avoids it —
      `device_shutdown()` runs on EVERY reboot path, so neither
      `talosctl reboot --mode=powercycle` nor `kexec_load_disabled=1` (the two
      levers that exist) skips the sequence where it hung. Only a
      hypervisor-level reset does, which is what the recovery already says.
      So what is left is: (a) detection, now covered by `NodeUnreachable`;
      (b) never wait on an in-guest reboot on OVH — go straight to Nova;
      (c) the root cause, which still needs the event to recur AND the serial
      console at that moment. Not schedulable — do not keep re-investigating it
      from the outside.

- [ ] **Roll the CNI metrics onto the live children.** Cilium now serves metrics
      (2026-07-29) and `check-cilium-parity.py` enforces the two keys, but the
      values only take effect on the NEXT bootstrap. Do not push the change onto
      a running child's HelmRelease — see the CNI mutation rule.

- [ ] **Close the watchdog loop outside the cluster.** A `Watchdog` alert now
      fires permanently and reaches Slack once a day, so the whole chain
      (rule → VMAlert → Alertmanager → Slack → egress) proves itself while it is
      alive — its ABSENCE is the signal. But absence only alarms someone if
      something outside the cluster is watching for it, and today that someone
      is a human noticing the daily message stopped. Point the watchdog route at
      a dead-man's-switch service (healthchecks.io, PagerDuty DMS…) instead: it
      is the only arrangement that survives the cluster dying, which was
      verified by killing etcd quorum — every metric correct in hindsight,
      nothing delivered at the time.

- [ ] **No per-object Ready condition for Flux.** `gotk_reconcile_condition`,
      which every monitoring guide still cites, is GONE in Flux 2.8.8 — the
      controllers expose only `gotk_reconcile_duration_seconds` and
      `controller_runtime_*`. `FluxReconciliationStalled` covers "stopped
      reconciling"; "reconciling but failing" still has no signal. A
      Kustomization blocked on a missing source counts as `requeue`, NOT
      `error`, so `controller_runtime_reconcile_total` misses it too.

      The route is kube-state-metrics `customResourceState`. Two sessions spent;
      here is everything ELIMINATED so nobody repeats it:
      * RBAC is not the cause — the chart already grants
        `customresourcedefinitions` list/watch whenever the feature is enabled,
        and `auth can-i list kustomizations` passes for the ServiceAccount.
      * the config is not rejected — KSM resolves the plurals and logs
        `familyNames=["gotk_resource_info"]` every time, including when it then
        serves nothing. That silent success is the whole trap.
      * label naming: upstream uses `exported_namespace`; `namespace` was tried
        and is not the difference on its own.
      * `--custom-resource-state-only=true` makes the instance serve ONLY these
        metrics — zero built-ins — so it can never share an instance with the
        one feeding the node/pod/volume/backup rules. A dedicated second KSM
        release is the only shape that could work.
      * ⚠️ It DID produce a series exactly once, with fluxcd's own values on a
        release named `kube-state-metrics` (`ready="False"` on a deliberately
        broken Kustomization). The SAME values on a release named
        `kube-state-metrics-flux` produced nothing, before and after 4 minutes,
        with and without `collectors: []`. Not reproducible, so nothing was
        shipped — a component that cannot be made to work on demand is worse
        than a documented gap.
      Next step is an upstream question with that reproduction, not more config
      guessing.

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
      Workaround: `skip_health_check`.
      Upstream, re-checked 2026-07-29: 0.11.0 is still the newest stable, the
      0.12.x line is alpha-only (now alpha.5) — nothing to adopt. The two open
      issues on this data source do NOT match: #241 is the 5-minute timeout cap
      (ours actually runs the configured 15 min), #206 is the kubelet-serving-CSR
      check (we never enable `rotate-server-certificates`). Ours is distinct: a
      bare `context deadline exceeded` with NO per-check output, so the stalled
      check is unknown.
      Narrowed 2026-07-29: a full Phase-2 apply on Scaleway passed the health
      check with no error, so this is NOT provider-agnostic — it is OVH and
      Outscale only. That belongs in the report; the old note called it generic.
      Blocked on evidence, not on a decision — filing it now would get it closed
      as un-actionable. Capture on the next OVH or Outscale run, from the host:
      `TF_LOG=DEBUG` for the failing read; `talosctl health` at the same moment
      (if that stalls too, it is not a provider bug); one run with
      `skip_kubernetes_checks = true` to isolate the K8s-level checks.

- [ ] **Keep trimming.** Done 2026-07-28: docs 2315 → 987 lines. The 50 comment
      blocks of 15+ lines were audited on 2026-07-29: nearly all are file
      headers or input contracts that earn their length, so only the
      `talos_cluster_health` blocks were cut. Do not trim by line count — cut
      where a comment narrates an incident instead of stating the why.

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
- **`up == 0` only works for NODE-discovered targets** — a node object outlives
  the node, so the target stays and reports 0 (etcd). A POD-discovered target
  leaves service discovery when the pod goes: the series disappears, and an
  absent series matches nothing (Cilium). For a DaemonSet, compare
  `number_ready < desired_number_scheduled` instead — but that says nothing
  about a dead node either, since DaemonSet pods tolerate `unreachable` with no
  timeout and are never evicted.
- **Check that a metric EXISTS before writing a rule on it** — every guide
  still documents `gotk_reconcile_condition`; Flux 2.8 no longer emits it, and a
  rule on a missing metric evaluates clean and never fires. `task check-alerts`
  asks a live cluster which referenced metrics have no data; it was written
  after finding three such rules by hand in one day.
- **A `VMRule` with no `VMAlert` is inert** — the operator stores it, nothing
  evaluates it, and no component reports the gap. The three backup rules sat
  like that from the day they were written until 2026-07-29.
- **kube-state-metrics needs `honorLabels: true`** — KSM reports OTHER objects,
  so without it the scraper's own labels win and KSM's become `exported_*`.
  Every rule selecting on `namespace`/`pod` then matches nothing, silently.
- **A component's metrics port is often its service port** — vmselect serves
  queries AND /metrics on 8481. Removing a CNP rule as "query-only" took the
  self-scrape down with it. Check `up == 0` after touching an observability CNP.
- **A batch translation leaves half-translated blocks** — a French sentence
  interleaved between English ones reads as finished and no linter catches it.
  Sweep with a detector, never trust "already done" (both `CLAUDE.md` claimed
  the repos were fully English while ~50 lines were not).
