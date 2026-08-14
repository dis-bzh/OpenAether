# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

Keep it short: one entry = the defect, its cost, what to do. Detail lives in the
code comment, the runbook or the commit message, referenced by path.

⚠️ This file drifted into a lab notebook (215 lines, one entry at 32) and was cut
back on 2026-07-29. If an entry starts explaining what was ruled out, the
explanation belongs in the commit that ruled it out.

## Where we stand

2026-08-14: **everything below was proven by a human running commands. Nothing
re-proves it.** `.github/workflows/staging.yml` is the answer to that and it has
never executed: it was merged 2026-08-13 with no `staging` environment and none
of its 17 secrets set, so its first scheduled fire would have died on an empty
blob — and a workflow that has never run looks exactly like one that passes.
Fixed today, except the part only a human can do: the environment exists
(deployment branch policy `main` only, no approval gate, so the weekly run is
not blocked), the lane now covers all three providers on the cron instead of
Scaleway alone, and it gained an idempotency stage and an upgrade stage that
does not retry the known failing apply. `scripts/dev/check-staging-secrets.sh`
names what is still missing; until someone runs those `gh secret set` commands,
the unattended lane is code, not coverage.

Also today: the first-apply-after-a-version-bump failure is no longer a
hypothesis. It is upstream #352 on `.machine_configuration_hash`, fixed in the
0.12.0 pre-release line only — see the entry below. Feint moved to 0.7.3, which
served both issues we filed (#74, #99); the emulated fixture tags six kinds now
and `task feint-test` is green on both providers, both lanes.

2026-08-13: **the three clouds each ran deploy → idempotency → Kubernetes upgrade
→ Talos upgrade, and all three passed.** Scaleway 3+3, OVH 3+3, Outscale 3+1;
every node upgraded in place with `rolling-replace --upgrade` rather than
replaced, every node back under its own name, `tofu plan` clean afterwards on
each. Torn down, no orphans anywhere. What that cost, in defects nobody could see
from a green pipeline: a reboot renamed nodes on every provider (the images are
`metal` builds, the names came from DHCP); a routine apply after an upgrade
proposed replacing all three control planes at once; `task test` deleted the
operator's kubeconfig; OVH was never idempotent; a worker could never be upgraded
in place; a node could not be fully drained; and a tfvars backup was not
gitignored.
The upgrade path itself is the headline — 1.0.0 shipped it unverified.

Since then, on the same day: a node CAN be fully drained. istiod ran a single
replica under a budget requiring one, which is what pinned it; with two, a worker
drained clean — exit 0, zero non-DaemonSet pods left, about a minute while
OpenBao's raft quorum settled. The six other zero-disruption budgets are correct
and transient.

Still open: the two applies a version bump needs, and the Outscale image lane,
which cannot replace an image for a reason now measured rather than guessed —
`create_before_destroy` was tried and reverted. Both below.

Alerting exists and is proven end to end: 19 rules, a real alert delivered to
Slack from a Scaleway cluster, and a `Watchdog` whose silence is the signal.
etcd, Cilium, Flux and cert-manager are scraped.

2026-07-30: the full 1.0.0 phased rollout ran end to end — a real 3-provider
fleet (management/Scaleway + edge-2/OVH + edge-3/Outscale, both edges
gitception-injected, `workload` profile autonomous), a real Talos/K8s rolling
upgrade proven zero-downtime on edge-2 (after fixing a real surge-FIP gap),
and a full `task fleet-down` teardown. CI hardened (SHA-pinned actions/hooks,
branch rulesets, object-collision gate) on both repos. Fleet is torn down;
the `1.0.0` tag was cut on 2026-07-31 (`2a4c7df`); 1.0.1 follows on 2026-08-11.

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
`1.0.0` was tagged the same day.

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

Every entry ends with what would close it: **a command, run and green — never an
intention** — and names the rung it needs (mocked / emulated / real cloud, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)), because "prove it on a real cluster"
and "run `task test`" are not the same cost. An entry hiding which one it needs
is an entry that gets picked up and put back down. **Decide:** replaces
**Closes:** when a question has to be settled first — a task-shaped entry
invites someone to build what nobody decided.

- [ ] **The infrastructure survives a rolling Talos upgrade; the databases do
      not.** Measured on Scaleway 2026-08-14, on a clean unattended run that
      reached this point with no intervention: deploy, Day-1 seeding, 35/35
      Kustomizations Ready, idempotency, Kubernetes 1.36.2→1.36.3, Talos
      1.13.7→1.13.8 in place on all six nodes, 13 probe FAILs in 1299 samples,
      `tofu plan` empty afterwards — and then **8 of 35 Kustomizations not Ready**,
      blocked on `cnpg` and `storage-backup-target`.
      The CNPG instance pods sit on `local-path-retain`, which is the right call
      and is argued in `apps/base/cnpg/cluster.yaml` (CNPG replicates itself;
      Longhorn underneath is an anti-pattern). The problem is that after their
      node reboots the pods stay `Completed` and the operator does not bring them
      back: `grafana-db` reported "Waiting for the instances to become active"
      and `zitadel-db` sat in "Switchover in progress" for over twenty minutes,
      on nodes that were Ready again.
      So a rolling upgrade is zero-downtime for the API and NOT for the platform's
      own databases, which nothing said until an unattended run asserted
      convergence twice — before and after.
      Diagnosed to the pod on 2026-08-14, second run: `kubectl drain` **evicts**,
      and a CNPG primary cannot be evicted — its PodDisruptionBudget forbids it
      until a switchover has happened, and with `local-path-retain` the instance
      could not move to another node even if it were allowed to. Setting
      `nodeMaintenanceWindow.inProgress=true` on every Cluster for the roll (now
      done) is not enough: the drain still timed out at 900s on `grafana-db-1`
      **and** `zitadel-db-1`, both primaries, both on the same worker.
      What made this destructive is fixed: the roll used to warn and reboot the
      node anyway, and now refuses. So the failure is loud and the databases
      survive — but the roll stops.
      **Decide:** switch the primary away before draining (CNPG's own verb — the
      `kubectl cnpg` plugin patches `status.targetPrimary`; doing it with plain
      kubectl means writing that subresource ourselves), or spread the primaries
      so one node never holds two, or accept a documented manual step. Note a
      third pod blocked the same drain, `kube-state-metrics`, which is not CNPG
      and needs its own look.
      **Closes:** a clean run where the post-upgrade check reaches 35/35. Rung:
      real cloud, and it reproduces every time.

- [ ] **`fleet-down` leaves the bastion SSH tunnels open.** Six were still
      listening after a teardown on 2026-08-14, pointing at a cluster that no
      longer existed. `talos-tunnels.sh open` now waits for the ports rather than
      racing them, so the next deploy recovers — but a teardown that leaves
      processes behind is a teardown that is not finished.
      **Closes:** `task fleet-down` followed by zero matching `ssh -L 5000x`
      processes. Rung: real cloud.

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

- [ ] **The first apply after a `talos_version` bump always fails, and it is an
      upstream bug we cannot take the fix for.** Reproduced on OVH and Outscale:
      apply reports "Provider produced inconsistent final plan" once per machine
      config, and re-running succeeds. Identified 2026-08-14 — it is
      `siderolabs/terraform-provider-talos` **#352**, on
      `.machine_configuration_hash`: when `machine_configuration_input` is
      unknown at plan time (the data source reads "during apply"), the provider
      keeps the OLD hash in the plan and recomputes it at apply, and OpenTofu
      rejects the change. That also explains why the second run works — the first
      apply resolves whatever was unknown, so the data source becomes readable at
      plan time and nothing is deferred.
      Fixed upstream by PR #359 (commit `024ce5a`, 2026-06-04), which ships in
      **0.12.0-alpha.3 and later only**. 0.11.0 is still the newest stable and is
      what `cluster/versions.tf` pins, so there is no patch to move to — the same
      0.12 dependency as the declarative-upgrade entry below.
      **Decide:** wait for 0.12 stable, or force a replace instead of an update
      (`replace_triggered_by` on a `terraform_data` carrying the version pair —
      a create plans the hash as unknown, so there is no prior value to be
      inconsistent with). The second is untested and must not be committed as a
      fix before it is.
      **Closes:** one apply after a version bump, exit 0, no retry. Rung: real
      cloud — it needs the data source to be deferred, which neither mocks nor
      the container lane can produce. `staging.yml`'s upgrade stage is where it
      will show, and it does not retry, on purpose.

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

- [ ] **Outscale cannot run the HA topology under its default quota.** 3 CP +
      3 workers of `tinav5.c2r7p2` is 42 GB against a 40 GB RAM quota, so the
      documented `OSC-mgmt-ha` case is unreachable without a quota request.
      `preflight-quotas` refuses correctly and explains why — the overrun is
      tolerated at creation and then every later VM is silently refused. Either
      raise the quota, or write the reduced topology (3 CP + 1 worker, 28 GB)
      into the example and the matrix so nobody plans around a case that cannot
      run.

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
