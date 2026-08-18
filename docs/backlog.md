# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

Keep it short: one entry = the defect, its cost, what to do. Detail lives in the
code comment, the runbook or the commit message, referenced by path.

⚠️ This file drifted into a lab notebook (215 lines, one entry at 32) and was cut
back on 2026-07-29. If an entry starts explaining what was ruled out, the
explanation belongs in the commit that ruled it out.

## Where we stand

2026-08-17: **the release restarts as 0.5.0, infrastructure only.** Every 1.x tag
and release was deleted on both repositories; 0.4.0 is the newest tag here, so
0.5.0 continues an uninterrupted sequence rather than reusing a number that has
already carried a published release. Scope, and nothing else: deploy, a healthy
HA cluster (Talos + Cilium), idempotency, Kubernetes and Talos upgrades, and an
encrypted tfstate replicated to a second store. Flux is disabled, not amputated
(`deploy_flux`, default false) and returns as a user choice afterwards.

**Where the five pillars actually stand, walked by the operator.** A result
nobody records is a result you pay to reproduce.

| | deploy | task verify | idempotency | k8s upgrade | Talos upgrade | longest outage |
|---|---|---|---|---|---|---|
| Docker | ✅ | ✅ 6/6 | ✅ empty plan | — | — | — |
| Scaleway | ✅ ~8 min | ✅ 9/9 | ✅ warm and cold | ✅ 1.36.2→1.36.3 | ✅ 6/6 nodes | **3 s** / 7 fails in 1817 |
| Outscale | ✅ 47+17 | ✅ **9/9, 0 unknown** | ✅ | ✅ 1.36.3 on 6/6 | ✅ **6/6, v1.13.8** | **1 s** / 1 fail in 470 |
| OVH | ✅ ~6 min | ✅ 7/8 | ✅ | ✅ | ⚠ one node, see below | — |

**Outscale closed on 2026-08-18**, and the Talos versions were confirmed from each
node's own API, not from Kubernetes alone. Getting there cost three real defects,
each of them ours and each now fixed: an image rebuild that deleted a snapshot its
own OMI still used; an upgrade path that needed the Talos API and never opened the
tunnels to it; and `running="$(talosctl version …)"` under `set -euo pipefail`,
which killed the roll five nodes into six with no message at all.

The single failure in both 7/8 runs was the same assertion — `s3_replica_endpoint
equals s3_primary_endpoint` — which was fatal everywhere at the time and is now a
warning outside `prod`. So `infra-verify.sh` HAS run against cloud clusters,
contrary to what its own history suggests, and would score 8/8 today.

**The claim to make about the upgrades is a number, not an adjective.** The probe
samples `/readyz` once a second through the load-balanced endpoint, and the
assertion is on the LONGEST CONSECUTIVE run of failures, not the total. "No
service interruption" is not measurable; "no consecutive outage longer than 15s
at 1 Hz" is, and that is what 0.5.0 asserts.

**Not proven, and each is an entry below**: no lane has ever run unattended to
completion; nothing has opened a stored object to confirm the state is
ciphertext; there is no working restore path; and the documented user journey
(`docs/first-cluster.md`, written 2026-08-17) was assembled by reading the code,
not by walking it.

### FIXED — the resume read the tfvars, which the run rewrites before it is true

`staging-upgrade.sh` decided what to do by reading the tfvars, and it rewrites
that file BEFORE the apply that makes it true. Interrupt in between and the file
asserts a version nobody runs; the next run reads it, concludes the step is done,
and skips it — permanently, while reporting success.

Demonstrated on Outscale 2026-08-18: an aborted run left
`kubernetes_version = v1.36.3`. Harmless there because the apply HAD landed, but
the same abort one step earlier would have skipped a Kubernetes upgrade for good.

Each axis is now decided by asking every node what it runs, and a MIXED fleet —
the exact state an interrupted roll leaves — forces the step instead of skipping
it. With no cluster answering it falls back to the tfvars and says so, rather
than presenting a claim as a reading.

Two things the testing caught that the change itself did not:
`set -e` killed the script whenever no node answered (empty grep, `pipefail`), so
the fallback was unreachable; and the first mutation — reverting to the tfvars —
did NOT redden the harness, because no scenario made the two sources disagree.
That scenario now exists and is the only one in the file that can tell the fix
from the bug.

### FIXED — the port guard passed in 0s, on every provider, since it was written

Outscale, 2026-08-18. `bootstrap-phase2` reported `✓ 6/6 tunnels up`, the guard
reported `Talos API answering` on all six endpoints in **0 seconds**, and the six
`talos_machine_configuration_apply` then spent **15 minutes each** before dying on

    connect: connection refused   (127.0.0.1:50000 … :50102)

Connection refused on the LOCAL port: the tunnels were not there at all.

The guard exists to prevent exactly that, and had never run. The local-exec
passes `ENDPOINT` and `NODE` and nothing else, so `talosctl get machinestatus`
failed with `failed to resolve configuration context: talos config file is
empty` — it never opened a socket. That string is not in the list of transport
errors the probe treats as "not there yet", so the probe returned true on its
first attempt. Reproduced verbatim.

It passed the same way on Scaleway and OVH; those nodes simply happened to be
ready, so nothing showed. A check that cannot fail is invisible until the day it
was the only thing standing between you and a quarter of an hour.

The probe now needs no configuration at all and separates three states, each
verified: a closed port fails (rc 1), a real TLS endpoint passes (rc 0), and a
TCP port with nothing behind it fails — that last one being the case the original
comment correctly warned a bare connect would miss.

Still open behind it: **why the tunnels died**. `talos-tunnels.sh open` reported
6/6 and nothing was listening fifteen minutes later. The guard will now say so in
seconds instead of hiding it, but the cause is not diagnosed.

### OPEN — Outscale puts a three-control-plane cluster in ONE subregion

Found by the operator on 2026-08-17, looking at a running deploy: every node in
`eu-west-2a`. Verified in the module, and it is not a configuration mistake:

    modules/providers/outscale/network.tf:28  subregion_name = var.availability_zones[0]
    modules/providers/outscale/network.tf:40  subregion_name = var.availability_zones[0]
    modules/providers/outscale/main.tf:116    subregion_name = var.availability_zones[0]

Three reads, always index 0, while the variable defaults to three subregions and
described itself as "Availability zones for node distribution". scw and ovh both
round-robin with `element(var.…, count.index)`; outscale is the only module that
does not, and the only one where a variable promises a spread it never performs.
`ReadSubregions` confirms eu-west-2a/b/c all exist and are `available`, so the
platform is not the limit.

Consequence: `OSC-mgmt-ha` is HA against a node failure and not against a
subregion failure. The matrix said so about the RAM quota and not about this.

**Why it is not a small fix.** On Outscale placement comes from the SUBNET, not
from an attribute on the VM. Spreading means one private subnet per subregion
(with its own ip_range), nodes round-robined across them, worker volumes in the
matching subregion, and a decision about the NAT service — one NAT is a single
egress failure domain, one per subregion needs a route table each. Turning
`outscale_subnet.private` into an indexed resource moves its address, which
replaces the subnet and everything attached to it: it can only be done on a fresh
deploy, never on a live cluster.

**Closes:** an Outscale deploy whose `kubectl get nodes -o wide` shows control
planes in at least two subregions, and `task verify` green. Rung: real cloud, and
it must be a new cluster. Until then the documentation says one subregion, which
it now does.

### FIXED — the Outscale image rebuild deleted a snapshot its own OMI still used

2026-08-18, upgrading the live Outscale cluster v1.13.7 → v1.13.8. `task upgrade`
died before touching a single node:

    Error: Unable to delete Snapshot
    409 Conflict — {"Type":"ResourceConflict","Code":"9094"}

The plan said it all: **`Plan: 3 to add, 1 to change, 2 to destroy`**. The image
was "1 to change" — OpenTofu meant to update it in place and swap the snapshot
underneath. An OMI's backing snapshot is immutable, so that update was never
possible; the provider reports `block_device_mappings` as updatable and OpenTofu
believed it. The native API confirmed the conflict rather than guessing it:
`ReadImages` showed the v1.13.7 OMI still referencing the snapshot being deleted.

Two changes in `modules/talos-image/outscale/main.tf`:

- `replace_triggered_by = [outscale_snapshot.talos]` on the image, which puts it
  back in the graph where it belongs — destroyed BEFORE the snapshot it is built
  on, because it depends on it.
- `create_before_destroy` on both. Destroy-first left the account with **no
  bootable Talos image for the length of the import** — measured beyond 60 min on
  Outscale — in the middle of an upgrade, and an import that then failed would
  leave neither the old artifact nor a new one.

Plan after the fix: `4 to add, 0 to change, 3 to destroy`, `+/-` on all three.
**VERIFIED by the apply, 2026-08-18**, and by the native API afterwards: the new
OMI is registered, the old OMI and the old snapshot are both gone, no 409. The
provider documents both halves of why — "You cannot delete snapshots that are
currently used by an OMI", and for the image itself "you can still use VMs
already launched from this OMI", so deregistering it under six running nodes is
allowed. scw has no lifecycle block and replaced 7/7 cleanly on 2026-08-17; ovh
and proxmox have a single image resource and no ordering to get wrong. The defect
was Outscale's alone.

**The wait is nothing like what we had written.** Upload 2m44s, then the snapshot
import 12:20:24 → OMI registered 12:28:40: **~8 minutes**, against the "> 60 min"
in the module comment from a single 2026-07-25 observation. One order of
magnitude between two points, so the honest statement is a range, not a number,
and it now appears in `first-cluster.md` and `upgrade.md` — where a user looks —
instead of only in a `.tf` comment.

### OPEN — the two S3 stores are the same provider, which is the one thing they must not be

Raised by the operator on 2026-08-18: the whole point of a second store is to
survive a provider, and every store we actually run is a second bucket on the
first provider. Checked, and it is worse than that.

- **Nothing validates it.** `cluster/variables.tf` has no `validation` block on
  `s3_replica_endpoint`; its description says "Prod: a different provider" and
  descriptions enforce nothing. The only assertion in the repository is
  `infra-verify.sh:220`, which runs AFTER the deploy — you pay, then learn.
- **Seven shipped `prod` examples violated the rule** the verifier applies:
  `workload-{scaleway,ovh,outscale,proxmox}` and
  `failover-{scaleway,outscale,proxmox}`, each `environment = "prod"` with the
  replica endpoint equal to the primary. Copying one deployed a prod cluster the
  project's own checker calls red. FIXED here — every prod example now shows a
  replica on another provider.
- **`first-cluster.md` claimed `prod` "requires" it.** It does not. FIXED.
- **The credential plumbing already exists and has never been used in anger:**
  `<PROV>_BACKUP_AWS_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY`, then a generic
  `BACKUP_AWS_*`, then a fallback to the primary keys (`lib/common.sh::s3_cred`).
  `.env.example` sets them to the primary's own keys for all three providers,
  with a comment to repoint them "for real DR". Nobody has.

**The two shapes to support, in the operator's words.** Either one provider and
no cross-store pretence, or store on A and backup on B, deliberately. The second
is the one that earns the design, and today nothing distinguishes them except an
`environment` string that gates one post-hoc warning.

**Closes:** a cluster on provider A whose state and artifacts replicate to
provider B with B's own keys, and then — the part that actually proves it — A
treated as gone: fetch the state and the artifacts from B alone and redeploy the
cluster on B. `envs/failover-*.tfvars.example` exists for exactly this role and
has never been run. Rung: real cloud, two accounts. Until then "survives a
provider" is a HYPOTHESIS with plumbing, not a property.

### OPEN — one Talos image at a time, and whether that matters

Same conversation. The image resource is a single `outscale_image` whose name
carries the version, so after an upgrade the previous OMI is gone. The question
was whether that removes the ability to roll back.

It does not, because **rollback does not go through the image**. `talosctl
rollback` — "Rollback a node to the previous installation" — switches the node
back to its other A/B partition, on the node, with no cloud image involved. The
OMI is only ever read to CREATE a VM. Nor did `create_before_destroy` make this
worse: destroy-first previously left a window with NO image at all, so the change
went from "sometimes zero" to "always exactly one".

What is genuinely lost is the ability to create a NEW node on the old version
without rebuilding its OMI first — measured at ~8 min on Outscale, and the Image
Factory schematic is deterministic, so the rebuild is byte-identical rather than
approximate. Judged not worth a `for_each` over a version list and permanent
snapshot storage. Recorded so the question is not re-opened from scratch.

**Reopen if:** a real upgrade ever needs a node created on the previous version
while the roll is still in flight.

### OPEN — neither state backend takes a lock

Found 2026-08-18 while deciding whether it was safe to run an image rebuild
alongside the operator. `infrastructure/opentofu/{cluster,talos-image}/backend.tf`
both declare `backend "s3"` with no `use_lockfile` and no lock table. Two applies
against the same state — two terminals, or an operator and an assistant — race,
and the loser's write is lost silently.

OpenTofu documents `use_lockfile = true` for S3-native locking, which needs
conditional writes (If-None-Match) from the object store. Whether Scaleway, OVH
and Outscale S3 all honour that is a HYPOTHESIS; each has to be tried.

**Closes:** `use_lockfile = true` on both backends, and on each of the three
providers a second apply started during the first one that is REFUSED with a lock
error rather than proceeding. Rung: real cloud, but cheap — a plan is enough to
take the lock.

### REFRAMED — `talosctl upgrade --wait` never returns, and it is not an OVH defect

2026-08-18, Outscale, six nodes upgraded v1.13.7 → v1.13.8. **Every single one**
hit the same wall the OVH entry below describes:

    * <node>: stage: BOOTING ready: true unmetCond: []
    ⚠ the upgrade watch did not return within 420s — asking the node itself
    ✓ <node> came back on v1.13.8 — the watch failed, the upgrade did not

Six for six, control planes and workers alike, and every node was on the new
version and Ready. So `--wait` not returning is **not** an OVH problem, and the
OVH entry below is at most partly about OVH: what OVH lacked was the bounded
watch and the fallback that asks the node. Outscale had both, and shipped a
clean upgrade through the same provider behaviour.

What this changes: the 420s `UPGRADE_WATCH_TIMEOUT` and the ask-the-node recovery
are not a workaround for one provider, they are the normal path. The open
question is narrower than it was — why does a node that reports `ready: true`
never reach `Running` for the watcher — and it is no longer blocking an upgrade
anywhere.

**Still open on OVH specifically:** a control plane came back on the PREVIOUS
version. That is a different symptom and is untouched by this.

### OPEN — the OVH upgrade does not complete, and here is what it looks like

2026-08-17, a second OVH cluster, deployed and torn down the same afternoon. The
roll was STOPPED by the operator because it was not progressing, not because
anything else went wrong.

**The symptom is the watch, not the install.** `talosctl upgrade --wait` prints,
repeatedly:

    * 10.0.0.x: stage: BOOTING ready: true unmetCond: []

The node reboots, reports itself ready, and never reaches `Running` as far as the
watcher is concerned — so `--wait` does not return. That is precisely the
condition under which Talos does not confirm an upgrade: the controller drops the
META `Upgrade` tag only on `Stage == Running && Status.Ready`, and an unconfirmed
upgrade is what gets reverted on a later boot. It ties the hang and the revert
into one mechanism instead of two mysteries.

**And the boot method changes across the upgrade — measured:**

    cp-0  v1.13.8   (no BOOT_IMAGE)
    cp-1  v1.13.8   (no BOOT_IMAGE)
    cp-2  v1.13.7   BOOT_IMAGE=/A/vmlinuz     ← not yet upgraded

So `BOOT_IMAGE=/A/vmlinuz` is what a NOT-YET-UPGRADED OVH node looks like, and an
upgraded one has none. The 2026-08-16 note read that line as "it booted partition
A"; it is better read as "it is back on its original GRUB entry", which is the
same family as talos#13967 (open, names legacy boot) and consistent with GRUB no
longer being used for new installs since Talos 1.10.

**Correction to that entry:** `bootedWithUKI` does not exist in the SecurityState
of Talos v1.13.8. The spec carries `secureBoot`, `selinuxState` and
`moduleSignatureEnforced`, nothing else. The usable signal is `BOOT_IMAGE` in
`/proc/cmdline`, via `talosctl read /proc/cmdline`.

**Closes:** an OVH roll where `--wait` returns on its own, or a diagnosis of why
`Running` is never reached — `talosctl logs machined` on a node stuck at BOOTING
is the next read. Rung: real cloud.

### OPEN — one OVH control plane boots the previous Talos version

Measured 2026-08-16, and narrower than it first looked: **cp-0 only**. The
installer wrote partition B and logged "installation of v1.13.8 complete" with
exit 0; both kubectl and talosctl then reported v1.13.8; forty minutes later the
node was back on v1.13.7 with `BOOT_IMAGE=/A/vmlinuz` on its kernel command line.
It happened twice on that node. **cp-1 and cp-2 upgraded in the same run and
stayed**, so it is neither the platform nor the installer image.

One confounder, and it is large: cp-0 had been left CORDONED by an earlier run
that died mid-roll, and it is the node every etcd health check is driven through.
Two candidates, neither proven — Talos reverting a boot entry that never reached
`Running && Ready` (documented upstream behaviour, `talos#9088`, closed as
intended), or a GRUB entry the OVH firmware does not boot (`talos#13967`, open,
names legacy boot; `/A/vmlinuz` is legacy GRUB, and since Talos 1.10 GRUB is not
used for new UEFI installs).

**Closes:** one clean OVH roll with no interrupted predecessor, plus, on any node
that comes back on the old version, `talosctl logs machined | grep -i "reverting
failed upgrade"` and `talosctl get securitystate -o yaml` (`bootedWithUKI`).
Rung: real cloud. Until then the backstop holds — the roll re-upgrades any node
not on the target and the end-of-run assertion fails if one is left behind — but
a node that REVERTS after a confirmed upgrade should say so rather than be
quietly upgraded again.

### OPEN — the unattended lane applies a plan nobody read

`.github/workflows/staging.yml:109` sets `TF_CLI_ARGS_apply: -auto-approve`. That
is not the same weakness as approving interactively: `tofu apply` with no plan
file computes a plan, shows it and applies THAT one, in the same run. With
`-auto-approve` after a separate `task plan`, the plan that was reviewed and the
plan that runs are two different computations — OpenTofu says so itself, "you
didn't use the -out option, so OpenTofu can't guarantee to take exactly these
actions".

`task plan OUT=…` and `task apply-plan PLAN=…` now exist (2026-08-17) so the lane
can review and apply the same bytes. It still does not use them.

**Closes:** staging.yml plans with `OUT=`, prints the plan, and applies it with
`apply-plan`; one green run per provider. Rung: real cloud, and only once the
lane has credentials at all.

### CLOSED by measurement — the five pillars, on Scaleway, 2026-08-17

Walked end to end on a live cluster by following `docs/first-cluster.md`.

| | |
|---|---|
| Talos image build | **52 s** (the repo had only "~1 h on Outscale") |
| Deploy | 43 + 17 resources, 3 CP + 3 workers + bastion, 2 zones |
| Healthy | `task verify` **9/9** — first run of infra-verify against any cloud |
| State encrypted | envelope keys `encrypted_data, encryption_version, lineage, meta, serial`; none of four known state strings in clear across 1.7 MB |
| Artifacts restorable | both stores, byte-identical to the live files |
| Idempotency | "No changes", exit 0 — warm AND cold |
| k8s 1.36.2 → 1.36.3 | applied |
| Talos 1.13.7 → 1.13.8 | **6/6 nodes**, no revert, plan empty afterwards |

The OVH revert therefore does not reproduce on Scaleway, on a cluster with no
interrupted predecessor — which is consistent with the cordoned-node confounder
recorded for it, and leaves that entry open on OVH alone.

**The interruption, measured** — the claim this release makes, as a number:

    probe: 7 FAIL in 1817 samples (~1s apart), longest outage 3s

Thirty minutes of upgrade, one second apart, against the load-balanced endpoint.
Three seconds of consecutive unavailability against the 15 s ceiling. Note the
two figures are different claims: seven scattered blips over a control-plane roll
is an HA cluster working; three in a row is the API being down, and three is what
the assertion is about.

**And the apps machinery is inert, verified rather than asserted.** The roll
reported "no CNPG CRD — no database to gate on" and "Longhorn not present —
skipping volume gate" on every one of the six nodes. The decision to leave those
~400 lines in rolling-replace.sh until after the tag rested on reading the
runtime probes; it now rests on watching them.


### MEASURED — `task plan` needed the tunnels, and took 15 minutes to say so

No longer a hypothesis. On a live Scaleway cluster, 2026-08-17, tunnels closed:
`task plan STRICT=1` ran for **15m10s** and died on

    Error: cluster health check failed
    waiting for etcd to be healthy: rpc error: code = Unavailable …
      with module.talos.data.talos_cluster_health.this[0], modules/talos/main.tf:576

which is `health_check_timeout`, and which names neither the tunnels nor the
cause. This is the command docs/first-cluster.md calls the idempotency
assertion, so a reader in a fresh terminal paid a quarter of an hour for a
diagnosis they then had to guess.

Fixed: a port probe before planning (4s instead of 15m), and `task tunnels`,
which did not exist — running `talos-tunnels.sh` by hand has no backend and no
credentials, falls back to `{}`, and reports "No bastion_ip in the state —
deploy the infrastructure first" against a cluster that is running.

Idempotency itself is PROVEN on Scaleway, warm and cold: "No changes. Your
infrastructure matches the configuration.", exit 0.

### OPEN — the restore path is proven offline, never against S3

`scripts/ops/restore-artifacts.sh` and `task restore-artifacts` are new on
2026-08-17: until then the repository could encrypt a kubeconfig and a
talosconfig to two stores and had no way to read them back, and `task failover`
— the nearest thing — stands up a NEW cluster rather than recovering access to
the one you have. Its four script paths were also broken (it resolved
`scripts/infrastructure/...`), so it died at its own guard for every provider.

What is proven: the round trip, offline, real `enc()` against real `dec()`, byte
for byte, wrong passphrase refused (`scripts/dev/test-restore.sh`, 7 assertions).
What is not: the transport. Nobody has fetched one of these objects from a real
bucket, and nobody has opened a stored tfstate to confirm it is ciphertext.

**Closes:** on the first paid run, `task restore-artifacts PROVIDER=<p>` returns
both artifacts and they match the live files, plus
`aws s3 cp s3://<state-bucket>/<cluster>.tfstate - | head -c 200` is not JSON.
Rung: real cloud, and free once the cluster exists.

### OPEN — nobody has deployed under a bucket_suffix

S3 bucket names are unique across a whole provider, not per account (Scaleway
"in our whole platform", OVH "within OVHcloud", Outscale per region), so the
hardcoded names made `task up`'s first billable step unrepeatable by any second
account. `bucket_suffix` (2026-08-17) is the discriminator; it is empty by
default, which keeps the existing names, and `task bucket-suffix` prints one.

Six places build a bucket name in two languages that cannot import each other;
`scripts/dev/test-bucket-names.sh` compares the derivations (18 assertions). But
every one of them is arithmetic on strings — **no deployment has ever run with a
non-empty suffix**, so the day someone sets one is the day the backend, the
image build and the verifier are first asked to agree on it for real.

**Closes:** one deploy with `bucket_suffix` set, reaching `task verify` green.
Rung: real cloud. Cheap to fold into a run that is happening anyway.

### FIXED — the hour was not the load balancer, it was not being told

2026-08-19. The operator's question after the OVH day was the right one: not "why
is this provider slow" but **"how do we make it transparent for users"**. Three
things, each one an hour that was actually spent:

1. **Nothing said the word "tainted".** A create that times out leaves the
   resource tainted, so re-running DESTROYS what the provider was still building.
   `task infra` now runs `scripts/internal/explain-failure.sh` from a Taskfile
   `defer:` guarded on `{{.EXIT_CODE}}` — verified on Task 3.52 that EXIT_CODE is
   populated on failure and empty on success, so it costs nothing when the apply
   works. It names the tainted addresses, says re-running destroys and rebuilds
   them, and prints the `tofu untaint` line for each.
2. **A failed teardown could not tell "retry" from "only the provider can lift
   this".** `fleet-down.sh` now captures the destroy transcript through a pipe
   (`pipefail` keeps the destroy's own status, and the pipeline does not return
   until tee has written, so there is no flush race) and classifies it. On a
   wedged-load-balancer signature it prints what to check for billing, tells the
   operator to put BOTH the provider's listing and the provider's refusal in the
   ticket, and says to move on.
3. **The documentation quoted 52s and stopped there.** `first-cluster.md` now
   states the apiserver LB is the slowest and only stranding step, gives the
   measured OVH figure, and says not to re-run blindly.

Proven offline, mutation-tested both ways in each case. `test-explain-failure.sh`
(8 assertions): report every resource instead of only tainted ones → 2 red; let a
broken `tofu` propagate → 1 red. `test-teardown.sh` grew 64 → **76**: make the
verdict fire on every failure → 2 red (it blames the provider for a quota error);
make it never fire → **6** red. That second number was 2 on the first attempt
because the mutation only broke one alternative of the pattern — the mutation was
partial, not the test weak, and it was worth the second look.

What none of this does is make the load balancer faster. It makes the twenty
minutes legible instead of frightening, and it stops the loop that turned twenty
minutes into an afternoon.

### OPEN — the same load balancer timeout, on a second provider, because the fix never travelled

2026-08-18, OVH. `openstack_lb_loadbalancer_v2.k8s` died at **9m51s** on "context
deadline exceeded", and the provider's native API then showed it **still
PENDING_CREATE sixteen minutes later**, with `operating_status: ONLINE`.

This is the entry below, on a different cloud. That one was diagnosed on
2026-08-16 and fixed with `timeouts { create = "30m" }` — **on the Outscale module
only**. Neither `modules/providers/ovh` nor `modules/providers/scw` had a
`timeouts` block anywhere, so both were still running on the provider default of
10 minutes. A lesson learned in one provider module and not carried to its
siblings is the same defect as `register-spoke.sh:26` keeping the `../` bug that
its neighbour documents having fixed "in four sibling scripts".

Both load balancers in both modules now carry it. **That is a necessary fix, not a
proven sufficient one**: nobody has watched an OVH Octavia LB reach ACTIVE, so
whether 30m is enough is a HYPOTHESIS.

**The cost is not the wait, it is the loop.** A create timeout leaves the resource
`tainted` in state, so re-running `task up` DESTROYS the load balancer that was
nearly ready and begins again. Anyone who reacts to the timeout by re-running pays
twice and learns nothing. Check first:

    tofu state pull | jq '.resources[]|select(.type|startswith("openstack_lb_"))|.instances[0].status'

and if the provider says ACTIVE, `tofu untaint` it instead of rebuilding.

**The escape hatch that already exists:** `k8s_lb_mode = "vip"` (ovh and scw only;
outscale rejects it by validation) skips Octavia entirely and reserves a private
port for a Talos Layer2 VIP. It is NOT a drop-in — `k8s_lb_ip` then returns a
PRIVATE address, so kubectl needs a tunnel and `docs/first-cluster.md` step 5 stops
being true. Trading a stuck LB for a changed access model is a decision, not a
workaround.

**Closes:** one OVH deploy that reaches a Ready cluster, and the measured time the
LB took. Rung: real cloud.

### OPEN — the Outscale apiserver load balancer never finishes provisioning

Pure-infra deploy, 2026-08-16: `outscale_load_balancer.k8s` (`modules/providers/
outscale/lb.tf:11`) — "timeout while waiting for state to become active (last
state: provisioning, timeout: 10m0s)". The provider default is 10 minutes and the
resource declares no `timeouts` block. This is also what wedged the Net for the
teardown afterwards.

**Closes:** `timeouts { create = "20m" }` on that resource, then one deploy that
reaches a Ready cluster. Rung: real cloud. Until then Outscale is out of the
0.5.0 definition of done.

### OPEN — `scripts/setup.sh` gave a toolchain that could not run the local rung

Fixed 2026-08-17 (helm pinned to 4.2.3, matching CI and the renderer), and kept
here as the shape to watch: three files pin the same tool and only one of them is
enforced. Invisible to anyone who already had helm 4 — which is everyone who has
worked on this repository.

## Open — work we can do

Every entry ends with what would close it: **a command, run and green — never an
intention** — and names the rung it needs (mocked / emulated / real cloud, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)), because "prove it on a real cluster"
and "run `task test`" are not the same cost. An entry hiding which one it needs
is an entry that gets picked up and put back down. **Decide:** replaces
**Closes:** when a question has to be settled first — a task-shaped entry
invites someone to build what nobody decided.

- [ ] **`task up` cannot add a node to a cluster it already bootstrapped.** Its
      `infra` step applies with `talos_bootstrap=true` once the cluster is
      bootstrapped (correctly — forcing false zeroes the counts), so it waits for
      the NEW node's Talos API through a tunnel that `task up` only opens on the
      NEXT step. Measured on Outscale and OVH 2026-08-15 scaling 1→3 and 3→4
      workers: the apply retries for its full 900s and gives up. The workaround
      is ugly and works — let the apply fail, open the tunnels once the state
      holds the new node, re-run — but it means the documented "re-run to resume"
      is untrue for any change that adds a node, and it would bite a cold shell
      re-running `task up` on an existing cluster too, since nothing has the
      tunnels open then either.
      **Decide:** open the tunnels before `infra` when the state is already
      bootstrapped, or split the apply so node creation and Talos configuration
      are separate phases again.
      **Closes:** `workers = N+1` in a tfvars, one `task up`, exit 0, N+1 nodes
      Ready. Rung: real cloud.

- [ ] **The installer fix is written and not proven.** The machine config now
      names `factory.talos.dev/installer/<schematic>:<version>` so a reinstall
      keeps the schematic's extensions, and `talos-image.sh` refuses to build
      when the pinned id and `schematic.yaml` disagree. What is NOT established
      is that it cures the symptom: reinstalling one worker from the Factory
      installer at the SAME version (v1.13.8 → v1.13.8) left the node reporting
      zero extensions and `longhorn-manager` still crash-looping, so either a
      same-version upgrade is a no-op inside the installer or something else is
      dropping them. The version-CHANGING case, which is the one the upgrade path
      uses, was never tried.
      **Closes:** a v1.13.7 → v1.13.8 roll after which `talosctl get extensions`
      lists all three and `storage-backup-target` is Ready. Rung: real cloud.

- [ ] **A cluster can end up with a Talos PKI the state no longer matches, and
      there is no way back.** OVH, 2026-08-15, after several interrupted applies
      (a flavour resize, then a teardown stopped part way, then a reconcile):
      `talosctl` against every control plane returned "certificate signed by
      unknown authority … candidate authority certificate 'talos'", with a
      talosconfig freshly regenerated from `talos_machine_secrets`, which was
      never destroyed and is `prevent_destroy`. Kubernetes stayed healthy
      throughout — six nodes Ready — so nothing else reported a problem, and
      `task infra` sat for 11 of its 15 minutes trying to reach nodes that would
      not trust it. Not diagnosed; the cluster was torn down.
      It matters because `talos_machine_secrets` takes `talos_version` and the
      provider replaces it when that changes: `prevent_destroy` turns that into a
      loud plan error rather than a silent new CA, which is the right behaviour,
      but this cluster had its version moved back and forth several times while
      applies were being killed.
      **Closes:** either a reproduction (version flip-flop + interrupted apply →
      CA mismatch) and a guard, or evidence that only an interrupted apply can do
      it and a documented recovery. Rung: real cloud.

- [ ] **`kubectl cnpg promote` does nothing here, and says it worked.** Plugin
      1.23.6 against a 1.23.1 operator: exit 0, "Node X in cluster Y will be
      promoted" on stdout, and `status.targetPrimary` unchanged. Measured three
      times on Scaleway 2026-08-15, on a healthy cluster and on one stuck
      mid-switchover. The operator does accept target changes — it sets them
      itself when a primary is evicted — so this is not a permissions problem.
      Nothing depends on it any more (the roll uses `enablePDB`), but the plugin
      is still what a human reaches for, and a tool that reports success while
      doing nothing is worse than one that is absent.
      **Closes:** a promote that moves `targetPrimary`, or the version pin that
      makes it move, or the instruction not to use it. Rung: real cloud.

- [ ] **A stuck CNPG switchover has no automatic way out.** Same run: draining
      two workers in sequence left `zitadel-db` with the old primary demoted and
      "waiting for the switchover to finish" while the target replica waited for
      WAL only a running primary would produce. Deadlock, 15 minutes, no
      progress; the third instance was healthy and ready the whole time.
      Restarting the operator did nothing. Deleting the target's pod resolved it
      in about a minute, both times; that recovery is now in `upgrade.md`.
      The roll no longer creates the conditions for it — `wait_cnpg_whole` gates
      each node on `readyInstances == instances` — but that is prevention, not a
      cure, and it is UNPROVEN: it was written after the clusters came down.
      **Closes:** two consecutive worker drains with the databases healthy at the
      end and no pod deleted by hand. Rung: real cloud.
      Still open behind it: whether the deadlock itself is worth reporting
      upstream, since a target replica that cannot catch up should not pin the
      old primary indefinitely when a caught-up replica is sitting there.

- [ ] **The OpenBao bootstrap jobs fail terminally and nothing retries them.**
      Both of them, on Outscale 2026-08-15: `openbao-init` hit its
      `activeDeadlineSeconds: 600` while the StatefulSet was still waiting to be
      scheduled, and `openbao-vault-bootstrap` then hit its 1800s while OpenBao
      was still sealed behind the first failure. `backoffLimit` does not help —
      a deadline is terminal. The unsealer waits for ever on a Secret that will
      never exist, the KV engine is never mounted, and the Flux DAG stops at
      seeding on a cluster where everything else is healthy. Deleting each Job so
      Flux recreates it fixed both in about two minutes.
      A deadline that is generous enough for the slowest cluster is not a fix
      either: it only moves the cliff. The job should wait for its dependency
      before starting its own clock, or something should notice a Failed Job.
      **Decide:** which of those two.
      **Closes:** a fresh deploy whose OpenBao is slow to schedule and still
      converges, unattended. Rung: real cloud.

- [ ] **Nothing states the minimum a cluster needs to be upgradable.** Two
      measurements, 2026-08-15: OVH's three `b3-8` workers sat at 78/99/100% of
      CPU requests and no node could be drained — the evicted pods had nowhere to
      go, so their budgets never recovered and the drain waited out its full 900s
      with no eviction error to show for it. Outscale at 3 CP + 1 worker deploys
      and then cannot host the platform: OpenBao's three replicas never schedule
      (the control planes are tainted, one worker is not enough), so the DAG stops
      at seeding. `upgrade.md` now says a roll needs one node's worth of spare
      capacity; the examples and `deployment-test-matrix.md` still do not say what
      that means per provider.
      **Closes:** a documented minimum per provider, and the shipped examples
      meeting it. Rung: real cloud for the numbers, which we now have.

- [ ] **Three Kyverno policies have been in Audit since they were written.**
      `require-security-context`, `restrict-image-registries` and
      `restrict-privileged` fire against cert-manager, the CAPI providers and
      OpenBao's init containers on every cluster. Audit is a decision if someone
      made it and a leak if nobody did; either way the count has never been
      driven down, so a NEW violation is invisible among the standing ones.
      **Decide:** exempt what is legitimately privileged by name and enforce the
      rest, or record why these three stay in Audit.
      **Closes:** zero unexplained violations on a fresh cluster. Rung: real
      cloud.

- [ ] **`check-language.sh` exists twice and nothing compares the copies.** The
      infra copy and the apps copy drifted apart until 2026-08-15, when widening
      one and not the other would have left 52 lines of French passing CI in the
      sibling repository. `check-skill-parity.sh` does exactly this job for the
      shared skills.
      **Closes:** the parity check covering it, or one copy and a documented way
      for the other repository to call it. Rung: `task test`.


- [ ] **The image lane holds one version per provider, and an upgrade needs two.
      Target 1.2.0.** `talos-image/` has a single image resource behind a single
      `talos-image.tfstate` per provider, so moving `talos_version` REPLACES the
      published image rather than adding one. Three consequences, found while
      setting up the 2026-08-14 real-cloud runs: deploying at N-1 to test an
      upgrade destroys the N image first; on Outscale that replacement is the
      known 409; and **the state and the account disagree about what exists**.
      Measured on Scaleway 2026-08-14: the lane's state holds v1.13.8, yet a
      v1.13.7 image is still in the account and a cluster pinned to it deployed
      fine — an orphan from an earlier pin that the state no longer tracks. So two
      versions can coexist, but only by accident, and only until a forward build
      destroys the one the state does track.
      A fourth consequence, 2026-08-15: **a cluster whose tfvars name a version
      the account no longer has cannot be DESTROYED either.** The destroy plan
      still evaluates the image data source, which answers "your query returned
      no results", and `fleet-down` stops partway — after taking the Talos
      config-apply resources out of state. Recovered by pointing the tfvars back
      at the version the account actually holds and re-running, but a teardown
      that depends on an image being present is a teardown that can be blocked by
      a rebuild.
      Rollback is the part that makes this 1.2.0 rather than a nicety: `--upgrade`
      moves forward, nothing moves back, and the ability to move back is currently
      luck. Keying the image resources by version
      (`for_each` over a set of versions to keep, with a retention of two) makes
      both the upgrade test and the rollback possible, and would let the Outscale
      lane add before it removes.
      **Closes:** two versions published simultaneously on one provider, then a
      node rolled BACK to the older one and rejoining healthy. Rung: real cloud.

- [ ] **The unattended lane has no credentials, so it proves nothing yet.**
      `scripts/dev/check-staging-secrets.sh` prints the 17 `gh secret set`
      commands. The three `STAGING_TFVARS_B64_*` must each pin `talos_version`
      and `kubernetes_version` **one patch below** `cluster/variables.tf` — that
      gap is the only thing the upgrade stage has to move, and it refuses to run
      rather than pass on an empty one.
      **Closes:** `check-staging-secrets.sh` green, then one `workflow_dispatch`
      per provider, green, `stages=full`. Rung: real cloud — that is the point
      of the lane.

- [ ] **Report boot-image drift, now that nothing else will.** Node resources
      ignore their image attribute, because otherwise a `talosctl upgrade` leaves
      the plan wanting to replace every node at once (see
      `modules/providers/provider-contract.md` § "Node image drift"). The cost is
      that a *deliberate* image change — a new schematic, different extensions —
      is now invisible to `tofu plan`, and only `rolling-replace --replace` will
      carry it. A preflight that compares each node's recorded image id against
      the one the tfvars now resolve to, and says so, would give that back
      without re-arming the footgun.
      **Closes:** a preflight that prints the drift on a cluster whose tfvars
      point at a newer image, and prints nothing on one that matches. Rung:
      real cloud (the image data source needs a live account).

- [ ] **Make the upgrade declarative once `talos_machine` ships in a stable
      provider.** The `siderolabs/talos` provider grew a `talos_machine`
      resource whose `image` argument "upgrades if running version differs", with
      `drain_on_upgrade` cordoning and uncordoning the node itself, and an
      `ignore_kubernetes_upgrade_drift` opt-in. None of it is in 0.11.0, the
      version we pin and the newest published stable — it lives in the
      0.12.0-alpha line. When 0.12 stabilises, that resource replaces the
      hand-rolled orchestration for version changes entirely, and
      `rolling-replace` shrinks back to what only it can do: instance_type,
      disk and zone changes that genuinely require a new VM.

- [ ] **Kubernetes upgrades bypass `talosctl upgrade-k8s`.** We move
      `kubernetes_version` in the machine config and let Talos reconcile. It
      works — measured 2026-08-13, 1.36.2 → 1.36.3 on a live HA cluster — but it
      skips the orchestrator Talos provides for exactly this, which sequences the
      control plane components and the kubelets behind health checks. Our run
      lost 3 probe seconds while an apiserver restarted; that is the gap
      `upgrade-k8s` exists to close.

- [ ] **The Outscale image lane cannot replace an image, and it is not an
      ordering problem.** Rebuilding fails with "409 ResourceConflict — Unable to
      delete Snapshot". Measured 2026-08-13, with the apply's own trace: the new
      snapshot imports fine (2m48s, not the hour this module's comment warns
      about), then the **deposed old snapshot** is destroyed while the **old OMI
      still references it** — the OMI is never deregistered first, and the apply
      dies before even creating the new one.
      `create_before_destroy` on both resources was tried and does NOT fix it: it
      changes when the new pair appears, not the fact that nothing deregisters the
      old image. Reverted rather than left in as a fix that is not one.
      **Decide:** whether the lane deregisters the OMI itself (a destroy-time step
      that waits for it to disappear) or whether replacing an image is documented
      as a two-step manual operation.
      **Closes:** `task talos-image PROVIDER=outscale` replacing an existing image
      in one run, exit 0. Rung: real cloud — it reproduces in about seven minutes,
      so this is cheap to iterate on.
      Noted alongside: `purge-orphans/outscale.py` reported "account is clean"
      while a duplicate snapshot from the failed run was sitting there. It does
      not look at snapshots or images.

- [ ] **Outscale cannot run the HA topology under its default quota, and the
      reduced one cannot run OpenAether.** 3 CP + 3 workers of `tinav5.c2r7p2` is
      42 GB against a 40 GB RAM quota; `preflight-quotas` refuses correctly and
      explains why — the overrun is tolerated at creation and every later VM is
      then silently refused. The escape this entry used to propose, writing the
      reduced 3 CP + 1 worker topology into the example, is now measured and
      closed off: it deploys and then stops at seeding, because the control
      planes are tainted and one worker cannot hold OpenBao's three replicas
      (2026-08-15).
      And three workers of that flavour are not enough either, for the same
      reason OVH's `b3-8` was not: `tinav5.c2r7p2` is 2 vCPU, the workers sat at
      93/81/35% of CPU requests, both CNPG clusters went to "Failing over" and
      Grafana crash-looped on a database with no primary. 34 of 35 Kustomizations
      Ready, and the missing one is the observability CRs.
      The arithmetic for the fix, read from `preflight-quotas` on 2026-08-15:
      7/10 instances, **14/20 vCPU**, 44/40 GB RAM. Moving the three workers to
      `tinav5.c4r7p2` costs +6 vCPU — exactly 20/20 — and no extra RAM. It fits,
      barely, and it is untested: Outscale updates `vm_type` in place with a
      stop/start, so applying it to six nodes at once would do to etcd what the
      OVH resize did.
      **Decide:** raise the quota, or move the workers to 4 vCPU one at a time.
      There is no working topology below three workers.
      **Closes:** `OSC-mgmt-ha` reaching 35/35 Kustomizations inside quota, then
      a worker roll finishing. Rung: real cloud.

- [ ] **`talos_machine_bootstrap` still needs a human after an interrupted
      apply.** The comment and the missing timeout are fixed; the behaviour is
      not. A bootstrap that succeeds on the node without being recorded in state
      still fails every later run with `AlreadyExists: etcd data directory is
      not empty`, against a healthy cluster, which contradicts the repo's own
      "re-run to resume". The recovery is now in the module header
      (`tofu import` the resource) but it is a manual step nobody will remember
      at 2am. Making it self-healing means either wrapping the call so
      AlreadyExists reads as success, or gating `count` on a data source that
      detects an already-bootstrapped etcd — both are design changes, not
      release-week edits. Decide, then do one.

- [ ] **Two checks in `test-talos-local.sh` are still warnings** — schedulable
      workers Ready, and Flux controllers running. Same shape as the CNI check
      made fatal in `01a081a`; left alone because the banner only claims
      `modules/talos`. Decide whether the banner moves or the checks do.

- [ ] **The stale `1.0.0 tag pending` line above is a warning, not an anecdote.**
      "Where we stand" said the tag was deferred for eleven days after it was
      cut, and it misled a reading of the project's own maturity. Re-read the
      top of this file at the end of a session, not only at the start.
      **Closes:** nothing recurring — it is a habit, kept honest by the next
      session noticing.

- [ ] **Three `dependsOn` edges are missing, and they only bite an ad-hoc pick.**
      `external-secrets-stores` is absent from `21-storage.yaml`,
      `20-cnpg.yaml` and `30-observability.yaml` though all three ship
      ExternalSecrets bound to `ClusterSecretStore openbao` — `pick.py cnpg`
      alone yields CNPG clusters waiting on secrets that can never exist. And
      `foundation-vault` ships an Istio `DestinationRule` with no mesh
      dependency; the fix is to MOVE that object to `services-gateway`, where
      its Secret already lives, not to drag the mesh into every vault pick.
      No shipped profile is affected — `workload` picks vault and gateway,
      `management` takes the whole base — which is why nothing caught them.
      **Closes:** `pick.py cnpg` and a vault-only pick each reaching Ready on
      the local Docker cluster. No cloud needed.

- [ ] **The only documented CAPI child on-ramp does not build.**
      `apps/clusters/example-scaleway.yaml.example:39` declares a HelmRepository
      at `source.toolkit.fluxcd.io/v2`, a version that does not exist. Fixing
      the version alone then collides with the unconditional
      `helmrepository-cilium.yaml`; the single correct fix is to delete those
      lines. Lines 96/103 also use `${CLUSTER_NAME}` where no `postBuild`
      reaches. Separately `edge-1.yaml` never got the three `CHILD_BACKUP_*`
      vars that `edge-2`/`edge-3` have and `child-gitops` declares required.
      **Closes:** `kustomize build apps/clusters` green with the example
      renamed and listed. Mocked.

- [ ] **Seven markdown files in OpenAether-apps are French at an
      English-canonical name**, with no `.fr.md` twin — including the CAPI
      credential-seeding runbook, the OpenBao unseal/rekey runbook and the
      backup README. `scripts/pick.py` mixes languages in its own `--help`,
      errors and docstrings, which is a stranger's first contact with the
      headline feature. And `apps/flux/README.md:68` documents the profile
      marker as `# Pioche :` where `pick.py:257` matches `# Pick: ` — the
      silent-blindness trap, left half-fixed.
      **Closes:** a detector in CI that fails on French outside `*.fr.md`,
      then a green run. Note an accent regex is not enough: accent-free French
      escapes it (`scripts/ops/preflight-quotas.py:138` and two `ovh/*.tf`
      lines were found that way).

- [ ] **`OpenAether-apps` still runs `gitleaks` bare.** Done in this repo
      (`.gitleaks-envdata.toml` + the `leaks` job on a PR's own commits); apps
      has the same exposure and none of it, and it is the repo the 2026-07-31
      IPs and the Outscale account id actually leaked from.
      **Closes:** the same two files copied across, plus
      `scripts/dev/check-gitleaks-rules.sh` — a ruleset that matches nothing
      passes silently, and two rules here did exactly that.

- [ ] **The `talos-image` lane hardcodes the project name into its buckets.**
      `scripts/bootstrap/talos-image.sh` builds `s3-openaether-<provider>-talos-image`
      and `-talos-staging` as literals, and `talos-image/variables.tf` defaults
      `staging_bucket` to `s3-openaether-scaleway-talos-staging`. Everywhere else
      the project comes from `cluster_name`'s first segment. A fork of this repo
      therefore creates buckets named after openaether, and the `.example` files
      cannot honestly describe the naming as derived. Already user-visible:
      `fleet-down.sh`'s manual-purge list prints the talos-image bucket as
      `s3-<cluster_name>-<provider>-talos-image`, so anyone not named openaether
      is pointed at a bucket that does not exist while the real one survives.
      **Closes:** the same `split("-", cluster_name)[0]` derivation, plus a note
      in the release checklist — an existing deployment's buckets do not rename
      themselves, so this needs a migration line, not just a code change.

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
      **Closes:** a human reaching Grafana through the gateway and logging in
      with a Zitadel account. Real cloud, and a browser — no rung below one can
      show a claim form.

- [~] **Flux has no per-object Ready signal.** `gotk_reconcile_condition` is gone
      in Flux 2.8; `FluxReconciliationStalled` covers "stopped", not "failing".
      The kube-state-metrics `customResourceState` route produced a series
      exactly once and could not be reproduced (elimination list in `9ac133d`).
      Asked upstream 2026-07-29: kubernetes/kube-state-metrics#3052. Waiting —
      do not spend more time guessing at config.
      **Closes:** that issue answered, then the series present on two consecutive
      scrapes. Any cluster running Flux 2.8 does — the local Docker root
      qualifies, no cloud needed.

- [ ] **A full emulated apply of the cluster root needs two routes, and two
      decisions reversed.** Measured on 0.6.0, 0.7.0 and 0.7.3, identical all
      three times (`task feint-record`). Genuinely missing: Scaleway LB (SW-5 `#17`)
      and public gateway (SW-6 `#18`). Declined *with a stated reason*, which is
      a different conversation: `ipam BookIP` (SW-4 `#11`) because addresses come
      from the subnet plan rather than a client reservation, and Outscale
      `CreateLoadBalancer` (OSC-5 `#16`) because the emulator has no data plane
      to hand a working DNS name for. Arguing either means arguing a real client
      is blocked, not that a metric is short. Until then the real root stops at
      `plan` and the CRUD cycle runs on `infrastructure/opentofu-feint`.
      **Closes:** `task feint-apply` reaching an apply on the *real* cluster root,
      both providers. Emulated.

- [ ] **Compare our providers' answers with a real cloud, using `feint shapes`
      (0.7.0).** `task feint-record` answers "what do we call that no pack
      serves"; this answers "does the shape match", which is the half a proxy
      cannot reach — a client signs the host it was configured with, so a real
      cloud behind a reverse proxy answers 401. 0.7.0 solved it with a
      per-provider signer rather than the DNS/TLS interception their `#76`
      proposed. Recording needs a real account, so it rides on the next
      real-cloud session; `feint shapes --check` then compares offline with no
      credential.
      **Closes:** `feint shapes --check` green against a recording. Real cloud
      for the recording only.

- [ ] **Outscale provider 1.x deprecates the top-level `region`.** The real path
      still sets it, so every real Outscale command warns; only the emulated
      path uses the `api {}` block. Moving real runs onto the block means
      building `https://api.<region>.outscale.com/api/v1` ourselves, i.e.
      hardcoding their DNS — decide which is worse before changing it.
      **Decide:** build the URL ourselves, or keep the warning on every real run.
      The answer belongs in a comment beside the provider block.

## Blocked on the world, not on us

Not work. Conditions. Do not re-investigate them from a desk.

- [ ] **`talos-image` root is outside the emulated lane.** It stages images
      through object storage, which Feint does not emulate (the Scaleway
      provider hardcodes the S3 endpoint in code — not redirectable).

- [ ] **Proxmox never applied for real** — needs the hardware. Plus Ansible host
      hardening, documented but absent from the repo.

- [ ] **OVH: a node can stay `ACTIVE` while dead.** `vp_reset` is virtio-pci's
      reset; `device_shutdown()` runs on every reboot path, so no Talos-side
      lever avoids it — only a hypervisor reset, which the recovery already
      prescribes. Detection is covered by `NodeUnreachable`. The root cause
      needs the incident to recur WITH the serial console attached.

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

- [ ] **The language detector cannot see user-facing output.** It reads prose
      only — Markdown outside fences, comment lines — because a French word in a
      string literal or an identifier is not a translation defect. But a heredoc
      printed to a terminal is prose, and `fleet-down.sh` shipped `<projet>`
      next to `<project>` in the same block for exactly that reason.
      **Decide:** whether the gain is worth the false positives on identifiers,
      or whether printed strings (`cat <<EOT`, `echo`, `printf`) are a narrow
      enough surface to read as prose on their own.
