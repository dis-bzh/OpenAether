# Backlog — identified improvements (source of truth)

Everything identified as **better than what exists today**, with the reasoning.
Fed session after session (human + assistant). Remove entries once done.

English only, on purpose: this file is rewritten every session and two language
copies would drift within a week. See `CLAUDE.md` § Langue.

## Where we stand (updated 2026-07-28)

✅ **NOTHING IS RUNNING — all 3 accounts verified empty** (2026-07-28, end of
session). OVH: 0 instances, 0 FIPs, 0 private networks. Scaleway: 0 instances,
0 IPs, 0 LBs, 0 volumes. Outscale: purge-orphans finds nothing. No local Talos
container. Test branch `capi-mgmt-test` deleted, its useful fix (the
`clusterctl-inventory` brick) carried over to `main`.

Deliberately kept: the S3 buckets (state, artifacts, restic backups) and the
Talos images — destroying them would cost the ability to restore, plus a rebuild
(~1 h on Outscale).

### What the 2026-07-28 session validated on real cloud

A **5-cluster fleet across 2 providers** ran and was then torn down:

| Cluster | Provider | Bootstrapped by | Flux | Nodes |
|---|---|---|---|---|
| management | OVH | OpenTofu | 37/37 | 6/6 |
| edge-1 | Scaleway | management | 19/19 | 2/2 |
| edge-2 | OVH | management | 19/19 | 2/2 |
| mgmt-capi | Scaleway | **CAPI (throwaway cluster)** | 14/14 | 2/2 |
| edge-capi | Scaleway | **mgmt-capi** | 19/19 | 2/2 |

Two distinct achievements:

- an OVH management drives a **Scaleway** child → gitception validated
  cross-provider **in both directions**;
- a management **born from CAPI** deploys its own child, then **manages itself**
  once the throwaway cluster is destroyed → see `capi-bootstrap.md`.

### Two teardown traps, paid for in cash today

1. **`task fleet-down` without `source .env.sh` fails while printing
   "finished".** `tofu` prompts interactively for `var.encryption_passphrase`,
   the destroy never starts, yet the script concludes with
   `✓ fleet-down terminé` after a `⚠ le destroy du management a échoué` buried
   in the output. **All 7 OVH VMs were still there.** To harden:
   `fleet-down.sh` should exit non-zero when a step fails.
2. **Never conclude "the account is empty" from truncated output.**
   `purge-orphans/ovh.py` lists servers **first**; a `| tail -12` cuts them off
   and makes a populated account look clean. Check the full output, or make an
   explicit API call.

### What the previous run VALIDATED on real cloud

The 5 workstreams delivered the day before without ever having run:

| Workstream | Evidence |
|---|---|
| Bastion Neutron port (`fixed_ip`) | 6/6 SSH tunnels |
| **Public ingress** | EndpointSlice → real pod; nodePorts **30080/30443**; OVH LB pools targeting those ports |
| CNPG PITR | `s3://…/cnpg/{grafana,zitadel}-db` substituted from `cluster-identity` |
| Per-cluster restic prefix | parent `openaether-dev-ovh` **vs** child `edge-2` — collision resolved |
| Longhorn `backupTarget` | URL substituted (after the API fix, see below) |
| Backup alerting | 3 rules accepted by the VM operator → **the PromQL is valid** |
| OpenBao internal TLS | 3/3 unsealed, HTTPS raft quorum, ESO `store validated`, 6 policies returning 204 — **and the same on the CHILD**, via gitception |

⚠️ **Grafana ↔ Zitadel SSO: PARTIALLY validated.** What is proven: the
`auth.generic_oauth` config loads with the right endpoints, the network path is
open on BOTH sides (Grafana egress CNP → Zitadel ingress, port 8080), and above
all **Grafana starts even though `secret/grafana/oidc` is not seeded** — the
`optional: true` guardrail does its job and access is not locked out.
**NOT validated**: the real login flow and the STRUCTURE of the roles claim.
That requires creating the application on the Zitadel side (console) then
seeding the secret — an operator step, see `docs/admin-access.md` § 4bis.

### What is left for the next run

1. **A real browser SSO login** — everything else is done (Zitadel app created,
   secret seeded, credentials injected into Grafana, scopes fixed). All that is
   missing is logging in to confirm the claim form we picked. If every account
   stays `Viewer`, inspect the token and substitute the project ID into
   `role_attribute_path` (procedure in the file).
2. **Gateway → UI path**: not testable until the PKI intermediate is signed
   OFFLINE (`admin-access.md` § 2) — the HTTPS listener stays `Invalid`. The
   code itself is hardened (`credentialName`, no more `insecureSkipVerify`).
3. **`providerID` on CAPI nodes** — see the dedicated section below. This is now
   the most structural item: without it, `MachineHealthCheck` cannot work.

The first two require a live cluster: replay them at the next deployment. The
full browser-test protocol (blocking prerequisite, tunnel, the 3 tests) is in
`docs/admin-access.md` § 4ter.

- [x] ~~**Convert the legacy French code comments**~~ → DONE (2026-07-28). Both
      repositories are now French-free: comments, Python docstrings, CLI
      messages, OpenTofu descriptions and shell output. ⚠️ One regression caught
      on the way: `pick.py` identified its generated profiles by the literal
      French header string, so translating it made `--check` silently skip every
      profile. Generator and detector are now aligned in English and the guard
      was re-tested against a deliberately stale profile. **Lesson**: before
      translating a string, check that no code compares it.
- [ ] **`apps/base/platform/ccm/scaleway` does not build — dead code.** Its
      `kustomization.yaml` lists a `helmrepository.yaml` that does not exist, so
      `kubectl kustomize` fails on it. Nothing references it: the brick is absent
      from the Flux DAG and from `bricks.yaml`, and the CCM was explicitly ruled
      out (see "Public ingress" below). It is the only one of the repo's 48
      kustomizations that fails to build. Either delete it, or restore the
      missing file and document why it is kept. Found 2026-07-28 while sweeping
      every kustomization.
- [ ] **`task validate` fails outside an S3 context.** `tofu init -backend=false`
      on the `cluster` root still demands AWS credentials ("No valid credential
      sources found"), when `-backend=false` is precisely meant to avoid that.
      The repo's credentials are prefixed (`SCW_AWS_*`, `OVH_AWS_*`) and resolved
      by `scripts/internal/`, which this task does not call. Net effect: a static
      check meant to run without cloud does not run. Observed 2026-07-28;
      `opentofu-local` validates fine.
- [ ] **`fleet-down.sh` must exit non-zero when a step fails.** Today it
      concludes `✓ fleet-down terminé` even when the management destroy never
      started — the `⚠` is buried in the output and a hurried operator believes
      the account is empty. Observed 2026-07-28 with 7 OVH VMs still running
      after a "success".

### Note: `local-path` directories at 0755 (NOT a code defect)

CNPG's `initdb` failed with `Permission denied`: their PVC directory had been
created `0755` instead of the `0777` the provisioner's `setup` script applies.
OpenBao's, created later, was correct — and the deployed script was intact
(`$VOL_DIR` not blanked, which incidentally **confirms the Flux substitution
isolation**). Likely cause: the provisioner Deployment rolled **6 times** during
the deployment, driven by successive fix pushes, and a volume request landed
during a transition. Re-provisioning was enough. To re-check on a run without
intermediate pushes before turning it into a debt entry.

## Defects found by the 2026-07-28 cloud run

Four real defects, **none visible in static analysis nor in local testing**:

- [x] ~~**OVH floating IP associations without a router `depends_on`**~~ —
      Neutron refuses the association until the subnet has an external route.
      Race → **intermittent** failure. All THREE associations were affected;
      only the bastion lost the race. A direct consequence of the previous day's
      `fixed_ip` fix: removing the first race revealed the second.
- [x] ~~**OpenBao brick violating the project's own Kyverno policies**~~ —
      `seccompProfile` at pod level instead of PER CONTAINER, and an
      `alpine/k8s` image without a registry prefix. **These violations had
      always existed** but never fired: OpenBao was created BEFORE Kyverno
      enforced. The delay introduced by `foundation-vault dependsOn
      cert-manager` (a TLS prerequisite) pushed it under admission control.
      ⚠️ **Lesson**: DAG ordering can mask a real non-compliance. A component
      that "passes" is not necessarily compliant — it may simply have arrived
      before the check.
- [x] ~~**OpenBao TLS CA in the wrong namespace**~~ — the vault brick's
      `kustomization.yaml` carries `namespace: foundation-vault`, and the
      Kustomize transformer overrides the namespace of EVERY resource. The CA
      therefore landed outside `cert-manager`, the only place a `ClusterIssuer`
      can read a `caBundleSecretRef`. Moved out into
      `apps/base/foundation/vault-ca`.
      ⚠️ **Method lesson**: missed locally because the test applied `tls.yaml`
      **directly** (`kubectl apply -f`), which bypasses the override.
      **Validating a file is not validating the brick** — locally, apply the
      DIRECTORY (`kubectl apply -k`), never an isolated file.
- [x] ~~**Longhorn `backup-target`: API removed**~~ — Longhorn ≥ 1.6 moved the
      backup destination out of `Setting` into a dedicated `BackupTarget` CRD;
      the webhook rejects the old name ("setting backup-target is not
      supported"). I had checked the `Setting` CRD SCHEMA without checking that
      `backup-target` was still a supported name.
      ⚠️ **Lesson**: confirming a field exists does not say the resource is the
      right one. Check the resource NAME against the deployed version.

## Grafana ↔ Zitadel SSO — real measurements (2026-07-28)

Taken against Zitadel **v4.14** on the OVH cluster, through the API (`iam-admin`
PAT, port-forward — the CNP blocks direct access from an arbitrary pod).

- ✅ **The 4 configured endpoints are EXACT**, confirmed by
  `/.well-known/openid-configuration`: `/oauth/v2/authorize`, `/oauth/v2/token`,
  `/oidc/v1/userinfo`, `/oidc/v1/end_session`.
- ❌ **The roles scope was missing — a real defect.** With `openid profile email`
  alone, `/oidc/v1/userinfo` contains **no** role claim at all: everyone would
  have silently fallen back to `Viewer`, whatever `role_attribute_path` said.
  Fixed by adding `urn:zitadel:iam:org:projects:roles`.
- ✅ **Claim structure confirmed**: the value is an OBJECT whose keys are the
  roles — `{"grafana-admin": {"<orgId>": "<domain>"}}`. `keys()` was therefore
  the right approach.
- ⚠️ **Claim name: two forms.** Measured
  `urn:zitadel:iam:org:project:<projectId>:roles` when asking for the roles of
  every project. The UNPREFIXED form applies to the project the client belongs
  to (Grafana's case), but that could not be reproduced without a real browser
  flow. To settle on the first login.
- Created on the Zitadel side: project `OpenAether`, role `grafana-admin`, web
  application `Grafana` (code + PKCE, redirect `…/login/generic_oauth`),
  `projectRoleAssertion` enabled. Credentials seeded into `secret/grafana/oidc`,
  ExternalSecret `SecretSynced`, variables injected into the Grafana pod.

## Backups / DR

- [x] ~~**One restic repository per cluster (prefix)**~~ → DONE (2026-07-27),
      design (a) chosen. The repository path becomes
      `s3:<endpoint>/<bucket>/<CLUSTER_NAME>/{openbao,cnpg}`.

      Full chain:
      - **parent**: `flux-bootstrap.yaml.tftpl` lays down a `cluster-identity`
        ConfigMap (ns flux-system) with
        `CLUSTER_NAME = <cluster>-<env>-<provider>` (the provider IS part of it:
        `openaether-dev` alone is identical on all three clouds, so it
        distinguishes nothing);
      - **children**: `child-gitops` lays down the same ConfigMap, its
        `${CHILD_NAME}` value substituted by the management from
        `apps/clusters/edge-*.yaml` (the CAPI name is already unique across the
        fleet);
      - **`backup-*-identity` bricks** (22a) copy the identity into
        `foundation-vault` / `foundation-databases`; the CronJobs read it at
        runtime through `envFrom.configMapRef`.

      ⚠️ **Major trap avoided**: putting `postBuild.substituteFrom` directly on
      the `backup-*` bricks would have blanked EVERY bare shell variable in
      their CronJobs (`$PRIMARY_ENDPOINT`, `$LEADER`, `$init_err`…) — Flux
      substitution applies to the entire render of a Kustomization. Hence two
      dedicated Kustomizations that render nothing but a ConfigMap. **Never
      merge these resources into `apps/base/backup/*`.**

      The CronJob refuses to run if `CLUSTER_NAME` is empty, with a message that
      points at the cause rather than a bare `set -u`.

      **Validated on the 2026-07-28 run**: parent `openaether-dev-ovh` vs child
      `edge-2`, then three distinct identities across the fleet.
      ⚠️ Operational corollary, unchanged: purge the prefixes of a destroyed
      cluster, or its escrowed password becomes the ONLY way to read its backups
      again. EXISTING (unprefixed) repositories stay in place: they will no
      longer be fed, and should be archived or deleted knowingly.

- [x] ~~**Backup failure alerting**~~ → DONE (2026-07-27):
      `apps/base/observability/vm-customresources/vmrule-backup.yaml`, 3 rules.
      `BackupJobFailed` (failed Job not retried, 15 min grace),
      **`BackupCronJobStale`** (no Job created for > 26 h — the most dangerous
      case, since there is then NO failure to look at) and
      `BackupCronJobSuspended` (> 6 h, warning: suspending is often deliberate,
      re-enabling gets forgotten).
      Placed in `vm-customresources/` rather than `observability/`: the `VMRule`
      kind only exists after the operator installs the CRDs — the same
      chicken-and-egg trap as VMCluster/VMAgent.
      The PromQL was accepted by the VM operator on the 2026-07-28 run, so it
      parses; the rules have not yet fired on a real failure.
- [x] ~~**Periodic restore test**~~ → DONE (2026-07-27): monthly
      `restore-test-cronjob.yaml` CronJob in BOTH backup bricks.
      Against both destinations: `restic check --read-data-subset=5%` (actually
      re-reads and DECRYPTS a fraction of the data — which `restic check` alone
      does not) then `restic restore latest` into a throwaway `emptyDir`, with
      **an assertion that the result is not empty**: a "successful" but empty
      restore means an unusable repository.
      The pods carry the `app: <cronjob>` label of the backup CronJobs — that is
      what the CiliumNetworkPolicy opening S3 egress selects; without the label,
      no egress. Their Jobs match `BackupJobFailed`, so a failed test alerts like
      a failed backup.
      **To validate at the next deployment** (not exercisable without a cluster).
- [x] ~~**CNPG PITR**~~ → ENABLED (2026-07-27) on both databases (zitadel-db,
      grafana-db). `barmanObjectStore` archives WAL continuously: the RPO drops
      from **24 h** (the only net was the daily `pg_dump`) to a few minutes.
      - destination `s3://${BACKUP_S3_BUCKET}/cnpg/<db>`, substituted from
        `cluster-identity`; credentials through the `cnpg-backup-s3`
        ExternalSecret (the same `backup/s3-primary` destination as restic and
        Longhorn);
      - **daily `ScheduledBackup` added**: without a base backup, archived WAL
        are unusable — the pair is what makes PITR;
      - 30-day retention, gzip compression for WAL and data.
      ⚠️ CNPG's `schedule` carries a leading SECONDS field (6 fields,
      robfig/cron format) — verified in the vendored CRD. With 5 fields, the
      hour would be read as minutes.
      Substitution is safe on this brick: the operator's vendored manifest
      contains `$(VAR_NAME)` occurrences, but **verified — all 13 are inside CRD
      `description` fields**, none in a container.
      Substitution confirmed on the 2026-07-28 run.
- [x] ~~**Longhorn `backupTarget`**~~ → WIRED (2026-07-27). Volumes had **no**
      backup destination at all: `backupTarget: ""` referred to a "cloud
      overlay" that never existed. Now:
      - `apps/base/storage/backup-target/`: `ExternalSecret`
        `longhorn-backup-credentials` (the 3 keys Longhorn expects —
        `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS` — from
        `secret/backup/s3-primary`, the same destination as the restic
        repositories) + a `BackupTarget` CR;
      - the URL comes from the `cluster-identity` ConfigMap, OpenTofu assembling
        it as `s3://<bucket>@<region>/` (`backup.tf`,
        `local.backup_data_bucket`). Assembled on the tofu side because Flux
        substitution cannot concatenate conditionally.
      - Kustomization `21c` is **separate** from `storage`: it carries the
        `substituteFrom`, and substitution applies to the whole render — merged,
        it would blank `$VOL_DIR` in `install.yaml`. Same trap as the backups.
      - A CR rather than the chart's `defaultSettings`: the latter is only read
        on first deployment, CRs survive upgrades.
      ⚠️ **API corrected on 2026-07-28**: Longhorn ≥ 1.6 uses a dedicated
      `BackupTarget` CRD (`longhorn.io/v1beta2`), not a `Setting` named
      `backup-target` — the webhook rejects the old name.
      Empty default if the cluster does not publish the URL — CAPI children,
      which do not pick `storage`, keep the current behaviour. Since the volumes
      are LUKS, the backups are encrypted by construction.
- [x] ~~**Scheduled etcd snapshot**~~ → DONE (2026-07-27):
      `scripts/ops/etcd-snapshot-cron.sh <provider> [key]`, crontab line
      documented in `docs/admin-access.md` § 3ter.
      The task alone was not cron-usable, for four reasons — all handled by the
      wrapper: cron's minimal `PATH` while the tools are scattered
      (`/usr/local/bin` and `/snap/bin`); credentials absent from cron's
      environment; **`task etcd-snapshot` opens SSH tunnels and never closes
      them** (fine interactively, but they would pile up under cron); and no
      guard against two overlapping runs.
      Verified for real with `PATH=/usr/bin:/bin`: the wrapper finds its tools,
      sources the environment, reaches the remote backend, then fails cleanly on
      the missing infrastructure — trap fired, non-zero exit, timestamped
      message.

## Observability / diagnostics

- [x] ~~**`cilium-dbg status` "Cluster health" structurally wrong**~~ → fixed
      (2026-07-27) by
      `apps/base/platform/network-policies/allow-cilium-health.yaml`.
      `default-deny-all-ingress` carries `endpointSelector: {}`, so it also
      covered the special `cilium-health` endpoints (one per node), whose ICMP +
      TCP 4240 probes were dropped. Every OpenAether cluster therefore reported
      **1/N reachable permanently**, each node seeing only its own.
      **This was not cosmetic**: on 2026-07-26 that false signal led to the
      conclusion that edge-2's inter-node datapath was "permanently broken" and
      motivated scrapping it. Verified on 2026-07-27: the management (32/32,
      6 nodes Ready) reported the same 1/6 while inter-node pod-to-pod worked
      (DNS resolved from a worker to the control-plane CoreDNS). After the fix:
      management **6/6**, edge-2 **2/2**.
      **Method lesson**: before concluding the datapath is broken from this
      signal, compare it against a healthy cluster — and confirm with a real
      traffic test (cross-node DNS, `kubectl exec`), never the probe alone.

## Architecture track — bootstrapping the management cluster via CAPI (2026-07-28)

Idea from [this article](https://blog.filador.ch/posts/a-la-decouverte-de-cluster-api-le-cluster-de-management/)
(Proxmox + CAPMOX + CABPT/CACPPT): add, **alongside** the OpenTofu path, the
ability to create the first cluster with CAPI and then make it self-managed.

**We were already 80 % there**: `cluster-api-operator` + CABPT v0.6.12 + CACPPT
v0.5.13 + CAPS/CAPO/CAPOSC are installed and **proven for real** (edge-1
Scaleway, edge-2 OpenStack). The cluster-description pattern already exists
(`apps/clusters/`).

### The real scope: CAPI does not replace OpenTofu

On OVH, OpenTofu creates **~44 resources of which only 3 are compute
instances**. The rest — network, router, 14 SG rules, LB + FIP, bastion, volume,
and the S3 buckets from `cluster/backup.tf` — has no CAPI equivalent. The honest
split is therefore:

> **OpenTofu = the substrate. CAPI = the machines.**

Which means we **remove nothing**: we add a third path. To weigh against "as
simple as possible".

### No need for `kind`

The article bootstraps on `kind`. We already have `task local-up` (local Talos)
**and** the pickable CAPI bricks. The ephemeral cluster can therefore be our own
— no new dependency, on an already-tested path:

`task local-up` → pick `cluster-api-providers` → describe the management in
`apps/clusters/` → pivot → `task local-down`.

### The hard part is not the pivot, it is **pivot × Flux**

`clusterctl move` assumes the CRs live ONLY in the cluster. Here Flux renders
them from git. The handover must be ordered: `Cluster` paused → `move` (it
carries the UID, `status` and `ownerReferences`, i.e. the Machine ↔ real
instance link) → the target's Flux **adopts** by SSA (same GVK/name/ns ⇒ patch,
not recreation). In the wrong order: either a second cluster is created, or
`prune` deletes what the `move` just laid down.
**That is where it would break — to be handled before writing a single line.**

### What it would actually buy (day-2, not day-1)

- **`MachineHealthCheck`**: a dead node is replaced on its own. OpenTofu cannot
  do that.
- **Talos upgrades** through a CACPPT rollout instead of our home-grown
  `rolling-replace` (ForceNew, one node at a time, etcd evict — delicate).
- Scaling = changing a number in git.
- One vocabulary: the management described like the edges.

### What it would cost

- A self-managed cluster **cannot repair itself**. A documented rescue path is
  needed (bring the local cluster back up, pivot in reverse).
- Coverage: **CAPMOX** (Proxmox) and **CAPD** (local) would be missing. Our 5
  OpenTofu providers would remain the reference regardless.

### ✅ VALIDATED END TO END on 2026-07-28 (Scaleway)

Full chain exercised: throwaway cluster → `mgmt-capi` → `edge-capi` →
`clusterctl move` → `task local-down`. `clusterctl describe`, run from
mgmt-capi itself, shows its entire tree `Ready`. Procedure and pitfalls:
**`capi-bootstrap.md`**.

The anticipated hard part — `pivot × Flux` — **did not happen**, for a reason
worth remembering: the pivoted objects belong to NO Flux inventory (they are not
in git), so `prune` never sees them. The cluster stayed healthy at 14/14. The
real risk only appears the day we want to describe the management in git:
`prune: true` on a Kustomization containing its own `Cluster` **would destroy
the cluster** if the file disappeared.

Two genuine obstacles were hit instead (see below): the missing clusterctl
inventory — **fixed** — and the absent `providerID` on nodes — **open, and it
affects the whole fleet**.

### Recommendation

Yes, **as an optional path**, first on OVH/Scaleway (proven providers), Proxmox
afterwards.

## ⛔ CAPI nodes without `providerID` — MachineHealthCheck inoperative (2026-07-28)

**The whole CAPI fleet is affected**: `edge-1`, `edge-2`, `mgmt-capi`,
`edge-capi`. Their `Machine` objects stay in phase `Provisioned` with
`status.nodeRef` **absent**, while the nodes are `Ready` and workloads run —
hence the defect going unnoticed until now.

Cause: Talos nodes have **no `spec.providerID`**. There is neither a
cloud-controller-manager nor `--provider-id` on the kubelet (verified through
`/proxy/configz`: empty `providerID`, no `uninitialized` taint, no topology
label). CAPI therefore cannot pair `Machine` ↔ `Node`.

What it costs, beyond the pivot:

- **`MachineHealthCheck` cannot work** — and that was argument number one in
  favour of CAPI for day-2 (automatic replacement of a dead node). As of today,
  that benefit **does not exist** here;
- deleting a `Machine` neither cordons nor drains its node;
- `clusterctl move` is refused ("still provisioning the node").

Validated workaround: copy the Machine's `providerID` onto the Node (see
`capi-bootstrap.md`). ⚠️ Go through the **instance UUID**, not the name: on the
control plane the node does not carry the Machine's name
(`mgmt-capi-cp-clmwj` → node `mgmt-capi-cp-cqqtl`).

Real fix, to be decided:

1. **A CCM per provider** (Scaleway CCM, OpenStack CCM…) — the standard route,
   but one more brick per provider, and credentials to manage;
2. **`provider-id` injected into the kubelet** by the Talos bootstrap — lighter,
   but the value is per machine: check whether CABPT can interpolate it.

To be handled before promising anything about self-healing.

- [x] ~~**`clusterctl move` refuses a management equipped by our operator**~~ →
      fixed (2026-07-28), the `clusterctl-inventory` brick.
      `cluster-api-operator` and `clusterctl` keep two distinct inventories: the
      former under `operator.cluster.x-k8s.io`, the latter under
      `clusterctl.cluster.x-k8s.io/Provider`, which only `clusterctl init`
      creates. A cluster equipped by the operator has the CRD but zero entries →
      "provider bootstrap-talos not found in the target cluster", while every
      controller is running. **`--dry-run` does NOT perform this check**: it
      passes completely, and the failure only surfaces on the real move. The
      brick's versions must stay aligned with `core-providers.yaml` /
      `infra-providers.yaml`.

## Multi-provider / infra

- [x] ~~**OVH: bastion port without `fixed_ip` → intermittent apply**~~ → fixed
      (2026-07-27). `openstack_networking_port_v2.bastion` declared only
      `network_id`, which creates **no dependency on the subnet**: OpenTofu could
      create the port first and Neutron would leave it without an IPv4. The apply
      then broke much further along, on two messages that do not name the cause:
      "Port <id> requires a FixedIP in order to be used" (bastion boot) and
      "Cannot add floating IP to port <id> that has no fixed IPv4 addresses".
      **It is a race**: several OVH deployments went through without it. The
      control-plane ports and the VIP already declared their `fixed_ip` — the
      bastion was the only outlier. **General lesson**: on Neutron, a port you
      expect an IP from must always carry a `fixed_ip { subnet_id = … }` block,
      as much for ordering as for allocation.

- [ ] **OVH: a node can stay `ACTIVE` on the hypervisor while being dead**
      (2026-07-27, `openaether-dev-cp-0`). Symptom: `Kubelet stopped posting node
      status`, static pods `Terminating`, and the **Talos API itself** resetting
      the connection (`apid` silent) while `cp-1`/`cp-2` answer through the same
      tunnels. Diagnosis through the **Nova serial console**
      (`os-getConsoleOutput`): Talos `init` called `reboot()` (`__se_sys_reboot`
      → `kernel_restart`) and the kernel **hung shutting devices down** —
      `device_shutdown` → `vp_reset [virtio_pci]` — with
      `rcu: INFO: rcu_preempt self-detected stall on CPU 0` looping in
      `virtnet_poll`. The VM never completes its reboot.
      `os-instance-actions` lists only the `create`: the reboot came **from
      inside**, it is not a platform action.
      Recovery: a `HARD` type `reboot` through the Nova API (the ACPI reset is
      useless, the guest is already stuck in its own reboot).
      To dig into: **why did Talos request that reboot** (no config apply was in
      flight at the time); is this a known 6.18 kernel / virtio shutdown hang?
      **Method to remember**: when `talosctl` resets the connection on ONE node
      and answers on the others, go straight to the provider's serial console —
      it is the only channel left once apid is dead.

- [x] ~~**OVH: floating IP associations without `depends_on` on the router**~~ →
      fixed (2026-07-28), found on the **first apply** of the validation run.
      Neutron REFUSES to associate a FIP until the port's subnet has a route to
      the external network:
      `ExternalGatewayForFloatingIPNotFound: External network <id> is not
      reachable from subnet <id>`. No reference linked
      `openstack_networking_floatingip_associate_v2` to
      `openstack_networking_router_interface_v2` → created in PARALLEL, hence an
      **intermittent failure** depending on who wins the race.
      **All THREE associations** in the module were affected (bastion, k8s LB,
      app LB); only the bastion lost the race, both LBs getting through by luck —
      a load balancer is slower to create. All three were fixed, not just the one
      that failed.
      **A direct consequence of the previous day's `fixed_ip` fix**: it removed
      the first race and thereby revealed the second. Lesson: on Neutron, a
      resource that depends on a network path must declare it — `network_id` or a
      bare `port_id` are not enough to order the graph.

- [ ] **Outscale RAM quota: an HA management saturates the account** (2026-07-26).
      `memory_limit` = **40 GB**, while an HA management (3 CP + 3 workers on
      tinav5.c2r7p2 = 7 GB + a 2 GB bastion) consumes **44** — the overrun is
      tolerated at creation, but ANY further VM is then refused:
      `CreateVms → 10042 TooManyResources (QuotaExceeded)`, whatever the size.
      Consequence: on this account, an HA Outscale management **and** a local
      child cluster are mutually exclusive (edge-3 disabled).
      Other tight quotas: `core_limit` 20 (14 used), `vm_limit` 10 (7).
      Diagnostic trap: the OscMachine stays `VmNotReady` with an endlessly
      reallocated IP and NO error in the CR — you have to read the CAPOSC
      manager's logs.
      (b) and (c) DONE (2026-07-27): `task preflight-quotas PROVIDER=…`
      (`scripts/ops/preflight-quotas.py`, read-only) shows real quotas and usage
      and **simulates** a topology (`--add-vms/--add-cores/--add-ram-gb`),
      exiting non-zero if it overflows. Verified on both accounts: it correctly
      rejects the HA Outscale management (44 GB for 40) and validates the OVH
      topology actually deployed (9/10 instances). All three providers' quotas
      are tabulated in `docs/admin-access.md` § 3bis.
      Remaining (a), an operator decision: request a quota increase from Outscale
      if we want the full fleet (HA management + child).

- [ ] **Simultaneous reboot of the whole Outscale fleet observed** (2026-07-26,
      14:32→14:34 UTC): all 6 VMs (3 CP + 3 workers) restarted within 2 min, with
      no action from us (no apply in flight, Node objects preserved, Talos
      `initialize sequence` = cold boot). A platform event, not a foundation
      defect — and the cluster came back **on its own** (etcd regained quorum,
      DAG back to 29/32 without intervention), which incidentally validates the
      resilience. Two takeaways: (a) the API was unreachable ~3 min and the
      2×10 s LB health check fixed earlier did bound the outage; (b) a 15-minute
      Flux health check (`storage`/Longhorn) expires if the reboot lands inside
      its window — it recovers on the next reconcile, but the "health check
      failed" message is then a false positive not to over-read.
      To do: never conclude an application bug without first checking
      `talosctl logs machined | head` (boot time) on several nodes.

- [x] ~~OVH Talos images: in-place rename~~ → DONE: `replace_triggered_by` on
      `terraform_data.build` (OVH) and `build_and_upload` (Outscale), plus
      `timeouts { create = "120m" }` on the Outscale snapshot (import > 60 min).
- [x] ~~E2e CAPI children on OVH + Outscale~~ → DONE (2026-07-25).
- [x] ~~Full management outside Scaleway~~ → DONE (2026-07-26): HA management,
      3 CP + 3 workers on **OVH**, DAG 30/30, driving the 3 edges (SCW, OVH,
      OSC) + cross-provider backups OVH→Scaleway. Revealed 3 defects in the OVH
      module (multiattach volumes, bastion_user, AZ 'any'), all fixed.
      STILL outside Scaleway: live rolling-replace, Outscale management.
- [x] ~~**OpenStack CP FIP created outside CAPI**~~ → pre-creation **scripted and
      idempotent** (2026-07-27): `scripts/ops/ensure-capo-fip.py <child>` finds
      the FIP by its description (`openaether:<cluster>`), only allocates one if
      none exists, and prints the address to carry into `OS_CP_FLOATING_IPS`.
      Re-runnable without creating a billed duplicate.
      A one-line manual carry-over remains **on purpose**: the IP must go into
      the Talos `certSANs`, hence into git, before boot. ⚠️ The pool uses
      `reclaimPolicy: Retain` — switching it to `Delete` would **destroy the IP**
      when the pool is removed, and the certSAN in git would become wrong.
      Only worth automating further if we want zero manual steps: a dedicated
      `tofu` root for a child's "pre-CAPI" resources.
- [~] **`talos_cluster_health` times out on a HEALTHY cluster — GENERIC DEFECT**:
      reproduced identically on **OVH then Outscale** (3 CP + 3 workers, all
      Ready, etcd HEALTH OK on all 3 CPs, complete Flux DAG). Neither a duration
      problem (15 min) nor a provider quirk; the SG hypothesis is ruled out
      (inter-node rule = all intra-SG traffic). Not observed on Scaleway
      managements. Workaround: `skip_health_check` (enabled in
      management-{ovh,outscale}.tfvars).

      **The DAMAGE is fixed (2026-07-27)**: `talos_cluster_kubeconfig` no longer
      depends on the health check. It used to, so an expiry failed the apply
      BEFORE the outputs — losing both kubeconfig AND talosconfig, plus the
      artifact backup, on a healthy cluster. Decoupled, the health check still
      fails the apply (the signal remains) but the kubeconfig is in state:
      `task kubeconfig` works and `task bootstrap-phase2` resumes. This entry
      merges the former duplicate "timeout too short in multi-AZ HA" (same
      defect, hypothesis invalidated). The timeout is also already configurable
      (`health_check_timeout`, default 15 min).

      **Still open, upstream**: bumping the `siderolabs/talos` provider is NOT
      possible — checked against the registry on 2026-07-27, the 0.12.x line only
      has pre-releases (up to `0.12.0-alpha.5`), 0.11.0 remains the last stable.
      So: either wait for a stable 0.12.0, or open the upstream issue with the
      traces from both reproductions.
- [ ] **Proxmox**: first real apply (SYS-1) + Ansible host hardening (absent from
      the repo, only documented).
- [x] ~~**Public ingress: decide CCM vs LB-IPAM**~~ → DECIDED and wired
      (2026-07-27). **They were not two solutions to the same problem**: a CCM
      provisions a cloud LB from a `Service type=LoadBalancer`; LB-IPAM assigns
      the IP the Service carries INSIDE the cluster. The pool is private
      (172.16.12.240-254), so LB-IPAM produces no public IP, and the public IP
      already comes from an LB created by **OpenTofu** — not by a CCM.

      **Decision: LB-IPAM inside, public LB in OpenTofu, no CCM.** A CCM would
      push provider-specific annotations up into the `apps` layer, which is
      precisely the shared layer the architecture keeps agnostic (specifics live
      in `modules/providers/`); and it does not exist on Proxmox, which is in
      scope. As a bonus, one fewer component holding cloud credentials inside
      the cluster.

      **Wiring delivered** — the public path was broken because the LB targeted
      `worker:80/443` where nothing listens:
      - `apps/base/services-gateway/service-nodeport.yaml`: a dedicated NodePort
        Service, ports **FIXED at 30080/30443**, selecting the Gateway pods.
        Fixed because the LB is created in PHASE 1, before the cluster: it cannot
        discover a randomly allocated nodePort (30000-32767).
      - `app_lb_node_ports` in all 3 provider modules (scw/ovh/outscale): LB
        backends **and security group rules** repointed at them. Opening 80/443
        on the nodes would have achieved nothing.
      - The `openaether-gateway` CNP widened to the `host`/`remote-node`
        entities: with `externalTrafficPolicy: Cluster` the node SNATs the
        packet, so Cilium no longer sees `world` but the node — without this all
        public ingress is dropped.

      ⚠️ **Cross-repo contract**: the port numbers are duplicated on both sides,
      each file pointing at the other. A mismatch = an LB pointing at nothing,
      with no error anywhere.

      Istio's LoadBalancer Service and its private VIP are **unchanged**: the SSH
      tunnel administration path is untouched.
      **Validated on the 2026-07-28 run** (EndpointSlice → real pod, LB pools
      targeting 30080/30443).
      A CCM would become the right choice again if Proxmox left the scope, or for
      on-demand public LBs per application.
- [x] ~~**Cloud S3 for observability**~~ → WIRED (2026-07-27). Loki was reading
      `minio/root`: in the cloud its logs landed on the internal MinIO, hence on
      Longhorn volumes — which defeats the point of object storage. Now
      **credentials AND location** (endpoint + bucket) travel through the
      `loki-s3-credentials` Secret, injected via `valuesFrom`: moving from the
      internal MinIO to the provider's S3 requires **no code change**, only a
      reseed of `observability/loki-s3`.
      The destination is deliberately **distinct from `backup/s3-primary`**:
      reusing it would give Loki write access to the backup bucket — a
      compromised Loki could erase them.
      No Flux substitution on this brick: the Grafana dashboards contain
      `${datasource}` placeholders that would be blanked.
      ⚠️ Still to do when wiring real cloud: `rules.dns` on Loki's `toFQDNs` CNP
      (the Cilium DNS proxy, without which toFQDNs never match).
- [x] ~~**`test-local-stack.sh` / fmt**~~ → settled (2026-07-27). Two halves:
      `infrastructure/.yamllint` **does exist** today (the entry was stale); and
      `tofu fmt -recursive infrastructure/opentofu` swept in the local scratch
      directory `_v2/`, failing `task lint` on `_v2/_test.tfvars`.
      `lint`/`fmt` now enumerate the real roots (`cluster`, `modules`,
      `talos-image`, `opentofu-local`) — **add any new root here**.
      `task lint` passes fully.
      Left for the operator: `infrastructure/opentofu/_v2/` is an untracked
      scratch directory (22 June) — to delete if unused. Untouched here: those
      are local files.
- [ ] **kyverno background-controller**: entry to REQUALIFY — checked on
      2026-07-27, **nothing disables it on the configuration side**. Rendering
      `apps/base/kyverno` does produce the 4 Deployments (admission, background,
      cleanup, reports) with no `replicas` override, and every ClusterPolicy
      carries `background: true`. The entry therefore describes an observed
      RUNTIME state, not a config choice.
      → To revisit at the next deployment: is the `kyverno-background-controller`
      Deployment running, and are `ClusterPolicyReport`s produced? If not, look
      at crashes/RBAC/resources, not at the manifests.

- [x] ~~**Kyverno installed from a remote GitHub URL**~~ → VENDORED (2026-07-27):
      `apps/base/kyverno/kyverno-1.12.1.yaml` (3.1 MB), with the source URL and
      **sha256** in a comment, plus the upgrade procedure. Flux reconciliation no
      longer depends on GitHub's availability, the render is reproducible
      offline, and the content is pinned (not just the version).
      Aligned with the repo's precedent: `cnpg-1.23.1.yaml` was already vendored
      for that reason ("avoids a remote fetch (DNS/IPv6)"), as are `cilium.yaml`
      and `flux-install.yaml` on the infra side.
      **Render verified IDENTICAL byte for byte** before and after the switch
      (3,179,903 bytes). Sweep done: NO remote base left in either repository.

## Reproducibility of generated artifacts

- [x] **`bootstrap-manifests/cilium*.yaml` had drifted from their generator** —
      both artifacts carried `cni-exclusive=false`, `bpf-lb-sock-hostns-only=true`
      and `nodeSelectorLabels=true` (hand-edited during an ambient debug), values
      that `render-bootstrap-manifests.sh` did not pass: regenerating silently
      broke Istio ambient. The `--set` flags are now in the script, with the
      reason. *(fixed 2026-07-26)*
- [x] ~~**Render non-regression test**~~ → DONE (2026-07-27): `task render-check`
      (= `render-bootstrap-manifests.sh --check`) replays the render into a
      throwaway directory and compares, writing nothing. It normalises trailing
      whitespace on BOTH sides, otherwise it would be permanently red: the
      committed artifact goes through the `trim trailing whitespace` pre-commit
      hook, helm's raw render does not.

      **The root cause of this whole bug class was found along the way: the
      script was writing into a PHANTOM directory.** It lives in
      `scripts/bootstrap/` but computed its output as
      `${SCRIPT_DIR}/../infrastructure/…`, i.e. `scripts/infrastructure/…`,
      created on the fly by its own `mkdir -p` and never read by OpenTofu.
      `task render-manifests` therefore appeared to work while **never**
      regenerating the committed artifacts — hence their drift, and hence the
      fact that `--set` flags had to be added by hand into the artifacts. Fixed
      to `../../`.

      The check paid off immediately: it caught that the generator's **local**
      mode was missing `socketLB.enabled=true`, which was present in the artifact
      (with its original comment). Regenerating would have produced
      `bpf-lb-sock: "false"`, making `bpf-lb-sock-hostns-only` inoperative and
      re-breaking hostNetwork pods' access to ClusterIPs. The `--set` was put
      back into the script; artifacts and generator are now aligned (verified key
      by key on the ConfigMap: 147 identical keys, 0 diverging value).

      Remaining: **pin `FLUX_VERSION`** — it is empty, hence `latest`, which
      makes `flux-install.yaml` non-reproducible and excluded from the check.
- [x] **`pick.py` profiles can go stale silently**: a profile freezes the list of
      *excluded* Kustomizations, so any brick added to the DAG is inherited from
      `../base` without having been picked (experienced: `orc` stuck on the
      edges). `pick.py --check` + `task apps-validate` detect the drift.
      *(2026-07-26)*

## Process debt

- [x] ~~Merge `feat/pioche-backup-gitception` → main~~ → DONE (2026-07-27): a
      single `main` branch in both repositories, `git_branch="main"` on the
      `cluster/main.tf` side, and no `CHILD_BRANCH` left in `apps/clusters/`.
- [x] ~~No CHANGELOG in apps~~ → DONE (2026-07-27):
      `OpenAether-apps/CHANGELOG.md`, started on that date. The 200 earlier
      commits are not retro-documented — the git history is authoritative, and
      the "why" behind decisions lives here, in this backlog.
- [x] ~~**Repository language**~~ → SETTLED (2026-07-28): English is the default
      for code comments, documentation and READMEs; French is a translation
      (`<name>.fr.md`), never the source. Recorded in both `CLAUDE.md` files.
      This backlog is English-only on purpose: it is rewritten every session and
      two copies would drift.
