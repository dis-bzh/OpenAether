# Backlog

What is left to do, and why. **Open items only** — a done entry belongs to git
history, not here. English only (rewritten every session; two copies would drift).

One entry = the defect, its cost, what to do. Detail lives in the code comment,
the runbook or the commit that closed it, referenced by path. Every entry ends
with **Closes:** — a command, run and green, never an intention — and names the
rung it needs (mocked / emulated / real cloud, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)). **Decide:** replaces it when a question
has to be settled first; a task-shaped entry invites someone to build what nobody
decided.

⚠️ This file twice drifted into a lab notebook — 215 lines on 2026-07-29, then
1449 on 2026-08-19, entries of 30 lines re-telling incidents that were already
fixed. Read the top of it at the END of a session too, not only at the start:
"Where we stand" is what the next person believes.

## Where we stand

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
353 offline assertions across 14 harnesses, every one mutation-tested; the
emulated lane runs feint 0.9.0 against Scaleway provider 2.81.0, the version the
clusters run.

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

**Not proven**: no lane has ever run unattended to completion; nobody has
deployed under a non-empty `bucket_suffix`; and the failover — provider A treated
as gone, the cluster rebuilt on B from B's replica alone — has never been
attempted.

**Resume here**: the interruption regression, then rolling-replace's two blind
applies, then decide whether 0.1.0 ships a staging lane at all.

## Open — infrastructure

- [ ] **The API is unreachable for seconds during a control-plane roll.** Same
      probe (`/readyz`, ~1 Hz, through the load-balanced endpoint), asserting on
      the LONGEST CONSECUTIVE run of failures:

      | | before | 2026-08-19/20 |
      |---|---|---|
      | Scaleway | 3 s, 7 fails in 1817 | **5 s**, 16 in 575 |
      | OVH | 1 s, 1 fail in 912 | **7 s**, 9-10 in ~540 |
      | Outscale | 1 s | **8 s**, 59 in 1179 |

      Three clouds moved the same way, so it is systemic. What the numbers rule
      OUT: the load balancer noticing a dead backend. It needs 5 checks × 15 s
      (Scaleway, OVH) or 3 × 10 s (Outscale) — 30 to 75 s, far LONGER than the
      gap. And only one CP is down at a time (`rolling-replace.sh:1309` gates on
      etcd 3/3), so two of three still serve: a missing backend gives
      INTERMITTENT failures, never a consecutive block.

      A consecutive block means no backend served at all, and the mechanism that
      does that is an etcd leader election — every apiserver fails during one.
      Supporting, not proof: a cluster bootstrapped once and rolled once reported
      `RAFT TERM 13`.

      Addressed 2026-08-20 by rolling the followers first and handing leadership
      over with `talosctl etcd forfeit-leadership` before the last CP — one
      chosen transition instead of three forced elections. The first roll under
      that order ran on Scaleway the same day, in the designed order (cp-0, cp-2,
      hand off, cp-1) and measured **2 s, 13 fails in 577**. That does **not**
      close this: the run moved Talos only, while the 5 s run also moved
      Kubernetes, which restarts an apiserver per CP by itself — two workloads,
      two numbers that do not compare. The kept timestamps do say something new:
      of the 13 failures only two adjacent pairs were consecutive, the rest
      isolated 5-6 s apart, so there were two real 2 s windows and not one long
      one. The experiment that settles it is the SAME Talos-only upgrade with the
      leader-last order disabled — one run, one variable.

      Still open behind it: the health checks are TCP on 6443, which cannot tell
      a listening port from a serving apiserver, so the LB keeps a not-ready CP
      in rotation for up to 75 s. HTTP on `/readyz` with a short interval would
      fix that — first verify `/readyz` answers unauthenticated on these
      clusters. And `--shutdown-delay-duration` on kube-apiserver would let it
      go not-ready BEFORE it stops, if Talos machine config can set it.
      **Closes:** a roll whose kept samples show zero consecutive failures, and
      the before/after to go with it. Rung: real cloud.

- [ ] **An infrastructure change must not break a running cluster.** Nothing has
      ever changed `vcpu`, `ram` or a disk size on a live cluster and watched
      what happens. Some of those force the provider to replace the instance,
      which on a control plane is an etcd member disappearing — the same event
      the roll now handles deliberately, except here it would come from a plain
      `cluster-up`. Whether the plan even routes such a change through
      rolling-replace, or applies it to all six nodes at once, is unverified.
      **Closes:** one bump of a node size on a live cluster, with the probe
      running, and the answer recorded either way. Rung: real cloud.

- [ ] **Nothing lets you ask what is in the state.** Reading it takes the root
      directory, its per-cluster `TF_DATA_DIR` and two credentials resolved
      through `resolve-s3-cred.sh` — four things to get right, and getting one
      wrong answers "No state file was found", which reads like an empty state
      rather than a mistyped command. `task kubeconfig` already re-inits a
      backend from a cold shell, so the machinery exists.
      **Closes:** `task state PROVIDER=…` listing entries from a fresh shell.
      Rung: real cloud, and it costs nothing.

- [ ] **Two harnesses failed once and passed on the next run, unchanged.**
      `test-gates-local.sh` and `test-cnpg-gates-local.sh`, 2026-08-20, run back
      to back in the same loop: red then green with no edit between. A test whose
      colour is not a function of the code under test is worse than no test,
      because a real failure is indistinguishable from the flake. Suspected but
      unverified: both spin something local and raced.
      **Closes:** the cause named, and the two run 20× consecutively green.
      Rung: mocked.

- [ ] **One apply still throws away the plan it decided on.** Everything else
      plans to a file and applies that file. `scripts/ops/rolling-replace.sh:1272`
      and `:1281` are two `-target` applies with `-auto-approve`; the safety plan
      above them has no `-out` either, so only the string `N to destroy` survives
      it and the guard that refuses to "apply blind" asserts against a plan that
      no longer exists. The second apply is neither planned nor counted. This is
      **Closes:** planning to a file, counting from that file, and applying it.
      `rolling-replace.sh:1108` prints the command in `--dry-run` and must change
      in the same commit. Rung: `task test`, then one real roll.

- [ ] **No state lock has ever been watched refuse a second run.**
      `use_lockfile` is now passed at init, and only where the store really
      locks: measured 2026-08-20 with one client against all three
      (`scripts/dev/probe-s3-conditional-write.sh`), Scaleway and OVH refuse the
      second conditional write and Outscale ACCEPTS it, so
      `scripts/internal/tf-backend.sh:44` claims the lock on the first two and
      not on Outscale — where nothing stops two runs against one state. The
      other half of the collision, two clusters fighting over one working
      directory, is separate and handled (`TF_DATA_DIR` per ROLE-PROVIDER,
      verified offline). What is missing is the only thing that proves a lock.
      **Closes:** on Scaleway and on OVH, a second run started during the first
      and REFUSED by name rather than proceeding — and, for Outscale, whatever
      is decided in place of a lock it cannot have. Rung: real cloud, but cheap
      — a plan is enough to take the lock.

- [ ] **The failover half of the two-store design has never been run.** The
      backup crosses a provider (proven 2026-08-19, ciphertext read back with the
      other cloud's keys), and the credentials now come from the cloud that HOLDS
      the bucket. What is untested is the only thing that makes it a property
      rather than plumbing: treat provider A as gone, fetch state and artifacts
      from B alone, redeploy the cluster on B. `envs/failover-*.tfvars.example`
      exists for exactly this role and has never been run. Nothing enforces the
      rule either — `cluster/variables.tf` has no `validation` on
      `s3_replica_endpoint`, only a description, and the single assertion
      (`infra-verify.sh:254`) runs after you have paid. The artifacts half is
      untested even at the transport: `test-restore.sh` proves `enc()` against
      `dec()` offline and says so itself, and `restore-artifacts.sh` was still
      resolving the wrong paths until 2026-08-18 — no kubeconfig or talosconfig
      has ever come back out of a real bucket.
      **Closes:** a cluster rebuilt on B from B's replica alone, reaching
      `task cluster-verify` green. Rung: real cloud, two accounts — with
      `task restore-artifacts PROVIDER=<p>` returning both files byte-identical
      to the live ones, which is free on any paid run.

- [ ] **Outscale puts a three-control-plane cluster in ONE subregion.** Three
      reads of `var.availability_zones[0]` (`modules/providers/outscale/
      network.tf:28,40`, `main.tf:116`) while the variable defaults to three and
      promises "node distribution"; scw and ovh both round-robin with
      `element(...)`. So the HA topology survives a node and not a subregion.
      Not a small fix: on Outscale placement comes from the SUBNET, so spreading
      means one subnet per subregion, volumes in the matching subregion, and a
      decision about the NAT service (one = a single egress failure domain).
      Indexing `outscale_subnet.private` moves its address and replaces
      everything attached to it — a fresh deploy only, never a live cluster.
      **Closes:** an Outscale deploy whose `kubectl get nodes -o wide` shows
      control planes in at least two subregions, `task cluster-verify` green.
      Rung: real cloud, new cluster.

- [ ] **`task cluster-up` cannot add a node to a cluster it already bootstrapped.**
      Its `infra` step applies with `talos_bootstrap=true` once bootstrapped
      (correctly — forcing false zeroes the counts), so it waits for the NEW
      node's Talos API through a tunnel it only opens on the NEXT step. Measured
      on Outscale and OVH 2026-08-15 scaling 1→3 and 3→4 workers: the apply
      retries its full 900s and gives up. The workaround works and is ugly (let
      it fail, open the tunnels, re-run), but "re-run to resume" is untrue for
      any change that adds a node, and for a cold shell too.
      **Decide:** open the tunnels before `infra` when the state is already
      bootstrapped, or split node creation and Talos configuration into separate
      phases again.
      **Closes:** `workers = N+1`, one `task cluster-up`, exit 0, N+1 nodes Ready.
      Rung: real cloud.

- [ ] **Two harnesses are weaker than the sentences they print.** Each of these
      is VERIFIED as a survivor of an adversarial pass.
      `test-talos-image.sh` — the `-var` assertion is anchored to `-var ` with a
      trailing space, so the `-var=` form passes while the message says it did
      not; nothing asserts the `$TGT` discriminator in the plan filename.
      `test-unattended.sh` — its "interactive exemption" is granted to any tty
      test whose block contains `exit` anywhere, so a script that PROMPTS but does
      not REFUSE headless is exempted and reaches the spend in CI unapproved: the
      exact defect the guard exists for. A heredoc opened inside `$( … )` makes
      its reader swallow the rest of the file in silence; `task -d <dir> <name>`
      resolves the flag's value as the callee; the anti-abuse assertion is a
      substring search, so any other spelling of the path escapes it, including
      invocation through a task target, which this repo already does. Its floors
      assert non-zero rather than the expected count, so a drop from six call
      sites to one is self-concealing, and `ENSURE: "{{.ENSURE}}"` passes because
      the check never asks whether the var it names is declared anywhere.
      **Closes:** a mutation for each shape, each seen to go red before it is
      believed; counts asserted against expected values. Rung: `task test`.

- [ ] **Encrypted worker volumes are applied and never verified.** The reference
      Scaleway cluster declares `worker_storage`, three `scaleway_block_volume`
      resources are in its state, and `modules/talos/main.tf:181` renders a LUKS2
      `UserVolumeConfig` per declared volume. Nothing asks a node whether those
      volumes exist, are encrypted, or are mounted at `/var/mnt/<name>` —
      `cluster-verify` has no volume check of any kind, so a UserVolumeConfig
      that silently failed to apply would look exactly like one that worked.
      The matrix said this was never applied at all, which was worse than
      untested: it was wrong (corrected 2026-08-20).
      **Closes:** a `cluster-verify` check that reads the volume back from the
      node's own Talos API, seen to fail on a cluster without them. Rung: real
      cloud, and the local Docker rung has no block volumes to stand in.

- [ ] **ovh.py cannot tell a refused question from an empty account.**
      `scaleway.py` and `outscale.py` both count refused calls and exit 2 when
      they found nothing but nothing was actually asked; `ovh.py` has no such
      counter. Its `get()` raises rather than swallowing, so a total auth failure
      crashes it non-zero rather than reporting clean — which is why this is a
      gap and not the same defect. But a partial refusal, one endpoint answering
      403 while the others answer, would still shrink the findings silently.
      Found 2026-08-20 while fixing the uncounted-deletion defect in all three.
      **Closes:** the same UNREACHABLE counter and exit 2, with the 403 scenario
      in `test-purge-orphans.sh` extended to ovh.py. Rung: mocked.

- [ ] **Deleting the staging lane left two things unchecked.** 0.1.0 ships no
      CI lane that deploys (decided 2026-08-20; the code is on the
      `archive/staging-lane` branch). Gone with it: the only automated proof that
      a bring-up works end to end without a human, and the full-platform verifier
      — so nothing now checks that `rolling-replace.sh` leaves no Kustomization
      suspended and no PodDisruptionBudget missing, which is the exact failure
      mode two of its comments warn about. Neither matters while Flux is
      disabled; both matter the day it returns.
      **Closes:** a lane that reaches a green deploy unattended, or a verifier
      that owns the post-roll Flux state. Rung: real cloud.

- [ ] **Why the tunnels died is still not diagnosed.** Outscale, 2026-08-18:
      `talos-tunnels.sh open` reported 6/6 up and nothing was listening on the
      local ports fifteen minutes later, which cost six 15-minute
      `talos_machine_configuration_apply` failures. The port guard that hid it is
      fixed and now fails in seconds, so the cost is bounded — the cause is not
      known.
      **Closes:** one reproduction with the ssh transcript kept, or a keepalive
      that makes it not matter. Rung: real cloud.

- [ ] **A cluster can end up with a Talos PKI the state no longer matches, and
      there is no way back.** OVH, 2026-08-15, after several interrupted applies:
      `talosctl` against every control plane returned "certificate signed by
      unknown authority", with a talosconfig freshly regenerated from
      `talos_machine_secrets` — which was never destroyed and is `prevent_destroy`.
      Kubernetes stayed healthy throughout, so nothing else reported a problem,
      and `task infra-apply` spent 11 of its 15 minutes trying to reach nodes that
      would not trust it. Not diagnosed; the cluster was torn down. It matters
      because `talos_machine_secrets` takes `talos_version`, and this cluster had
      its version moved back and forth while applies were being killed.
      **Closes:** either a reproduction (version flip-flop + interrupted apply →
      CA mismatch) and a guard, or evidence that only an interrupted apply can do
      it and a documented recovery. Rung: real cloud.

- [ ] **`talos_machine_bootstrap` still needs a human after an interrupted apply.**
      A bootstrap that succeeds on the node without being recorded in state fails
      every later run with `AlreadyExists: etcd data directory is not empty`,
      against a healthy cluster — which contradicts "re-run to resume". The
      recovery (`tofu import`) is in the module header, but nobody remembers a
      manual step at 2am. Self-healing means either treating AlreadyExists as
      success or gating `count` on a data source that detects an already
      bootstrapped etcd.
      **Decide:** which one, then do it. Rung: real cloud to prove it.

- [ ] **Nobody has deployed under a `bucket_suffix`.** S3 bucket names are unique
      per provider, not per account, so the discriminator is what makes the first
      billable step repeatable by a second account. Six places build a bucket name
      in two languages that cannot import each other and
      `scripts/dev/test-bucket-names.sh` compares the derivations (18 assertions)
      — but all of it is arithmetic on strings. The day someone sets a suffix is
      the day the backend, the image build and the verifier are first asked to
      agree on it for real.
      **Closes:** one deploy with `bucket_suffix` set reaching `task cluster-verify`
      green. Rung: real cloud, and free to fold into a run that is happening anyway.

- [ ] **The image lane holds one version per provider, so rollback is luck.**
      `talos-image/` has a single image resource per provider behind a single
      state, so moving `talos_version` REPLACES the published image instead of
      adding one: deploying at N-1 to test an upgrade destroys the N image first,
      and the state and the account can disagree about what exists (measured on
      Scaleway 2026-08-14 — an orphan v1.13.7 image the state no longer tracked
      deployed fine). Worse, 2026-08-15: **a cluster whose tfvars name a version
      the account no longer has cannot be DESTROYED**, because the destroy plan
      still evaluates the image data source and `fleet-down` stops partway, after
      taking the Talos config-apply resources out of state. `talosctl rollback`
      does not need an image (it switches the node's A/B partition), but creating
      a NEW node on the old version does, and that costs a rebuild (~8 min on
      Outscale, deterministic because the Factory schematic is content-addressed).
      **Closes:** two versions published simultaneously on one provider
      (`for_each` over a retained set), then a node created on the older one and
      rejoining healthy. Rung: real cloud. After 0.1.0.

- [ ] **Kubernetes upgrades bypass `talosctl upgrade-k8s`.** We move
      `kubernetes_version` in the machine config and let Talos reconcile. It works
      (1.36.2 → 1.36.3 on all three clouds), but it skips the orchestrator Talos
      provides for exactly this, which sequences control-plane components and
      kubelets behind health checks. That is the gap the entry above about the
      interruption is measuring, and the two should be read together.
      **Closes:** one roll through `upgrade-k8s` with the probe attached, compared
      against the current numbers. Rung: real cloud.

- [ ] **`purge-orphans/outscale.py` looks at neither snapshots nor images.** It
      reported "account is clean" while a duplicate snapshot from a failed image
      build was sitting there — verified again 2026-08-19: no snapshot or image
      handling in the file. A teardown proof that cannot see a whole resource
      class is a teardown proof that will one day bill.
      **Closes:** the same account, dirty with an orphan snapshot, reported dirty.
      Rung: real cloud, cheap.

- [ ] **Nothing states the capacity a cluster needs, per provider.** Two
      measurements: OVH's three `b3-8` workers sat at 78/99/100% of CPU requests
      and no node could be drained — evicted pods had nowhere to go, so budgets
      never recovered and the drain waited out its full 900s with no eviction
      error. Outscale's HA topology does not fit its default quota at all — 3 CP +
      3 workers of `tinav5.c2r7p2` is 42 GB against 40 GB, `preflight-quotas`
      refuses correctly, and the reduced 3 CP + 1 worker topology deploys and then
      cannot host anything (tainted control planes, one worker). The arithmetic
      for the fix, read 2026-08-15: moving the three workers to `tinav5.c4r7p2`
      costs +6 vCPU, exactly 20/20, no extra RAM — untested, and Outscale updates
      `vm_type` in place with a stop/start, so applying it to six nodes at once
      would do to etcd what the OVH resize did.
      **Closes:** a documented minimum per provider, and the shipped examples
      meeting it. Rung: real cloud for the numbers, which we now have.

- [ ] **One Talos image bucket is orphaned, and only a human can empty it.**
      `staging_bucket` became `import_bucket` and the bucket `…-talos-staging`
      became `…-talos-import` (2026-08-20), because this repository already
      spends "staging" on environments and reading it as one here is what it
      cost. The next build creates the new bucket and re-uploads; the OLD one
      keeps every QCOW2 it ever held, on every cloud that was built from, and
      nothing deletes it — `purge-orphans` enumerates by project prefix, so it
      WILL list it, but emptying a bucket is not something this repository does
      to a bucket it no longer names.
      **Closes:** `task purge-orphans PROVIDER=…` run per cloud after the first
      rebuild, the old bucket emptied and deleted, and a release-checklist line
      so the next rename does not repeat this. Rung: real cloud.

- [ ] **Scaleway never purges the QCOW2 it stages; Outscale does.** Outscale
      deletes the object once the OMI is registered
      (`talos-image/outscale/main.tf:188`) and explains why it can. The Scaleway
      module uploads, imports it as a block snapshot, and stops — so the bucket
      keeps one image per Talos version for ever, and nothing in the repository
      says whether that is a cache, a plan-stability requirement, or an oversight.
      HYPOTHESIS, untested: `scaleway_block_snapshot.talos` holds an
      `import { bucket, key }` block, so deleting the object may break every later
      plan — which is exactly the failure the Outscale comment says it avoided.
      **Closes:** the answer, written where the module is; then either a purge or
      one sentence saying why there is none. Rung: real cloud, one plan.

- [ ] **Three small tooling gaps, each one line of trust.**
      `test-talos-local.sh:244,263` — schedulable workers Ready and Flux
      controllers running are still warnings, the same shape as the CNI check
      that was made fatal; decide whether the banner moves or the checks do.
      `check-language.sh` exists in both repositories and nothing compares the
      copies — widening one and not the other would have left 52 lines of French
      passing CI in the sibling repo; `check-skill-parity.sh` does exactly this
      job for the shared skills.
      The language detector reads prose only, so it cannot see user-facing output
      — `fleet-down.sh` shipped `<projet>` next to `<project>` in one heredoc;
      **decide** whether printed strings (`cat <<EOT`, `echo`, `printf`) are a
      narrow enough surface to read as prose without drowning in identifiers.
      Rung: `task test` for all three.

- [ ] **Two feint gaps, both of them recordings we do not have.** A full emulated
      apply of the real cluster root needs the Scaleway LB (SW-5) and public
      gateway (SW-6); `ipam BookIP` and Outscale `CreateLoadBalancer` were
      declined with a stated reason (addresses come from the subnet plan; the
      emulator has no data plane to hand out a working DNS name), so arguing
      either means arguing a real client is blocked. Until then the real root
      stops at `plan` and the CRUD cycle runs on `infrastructure/opentofu-feint`.
      Separately, `feint shapes` compares our providers' answers against a real
      cloud, which a proxy cannot do alone — recording needs a real account and
      rides on the next real-cloud session, then `--check` runs offline.
      The measurements behind this predate feint 0.9.0 and must be re-run.
      **Closes:** `task feint-apply` reaching an apply on the real cluster root,
      both providers; `feint shapes --check` green against a recording.

- [ ] **Outscale provider 1.x deprecates the top-level `region`.** The real path
      still sets it, so every real Outscale command warns; only the emulated path
      uses the `api {}` block. Moving real runs onto the block means building
      `https://api.<region>.outscale.com/api/v1` ourselves, i.e. hardcoding their
      DNS.
      **Decide:** build the URL ourselves, or keep the warning. The answer belongs
      in a comment beside the provider block.

## Beyond 0.1.0 — the apps layer, which this release does not ship

Found on real clusters while Flux was still deployed. Kept because they are
measured and will bite the day `deploy_flux` is turned back on; each belongs to
`OpenAether-apps` work, not to this release.

- [ ] **The OpenBao bootstrap jobs fail terminally and nothing retries them.**
      Both hit their `activeDeadlineSeconds` waiting on a dependency;
      `backoffLimit` does not help, a deadline is terminal, and the DAG stops at
      seeding on an otherwise healthy cluster. A job must wait for its dependency
      before starting its own clock, or something must notice a Failed Job.
- [ ] **A stuck CNPG switchover has no automatic way out** — the old primary
      demoted, the target waiting for WAL only a running primary would produce.
      Deleting the target's pod resolves it; `wait_cnpg_whole` prevents the
      conditions but is UNPROVEN.
- [ ] **`kubectl cnpg promote` reports success and changes nothing** (plugin
      1.23.6 against a 1.23.1 operator, three times). Nothing depends on it, but
      it is what a human reaches for.
- [ ] **Three Kyverno policies have been in Audit since they were written**, so a
      new violation is invisible among the standing ones. Decide: exempt what is
      legitimately privileged, or record why they stay.
- [ ] **Three `dependsOn` edges are missing** — `external-secrets-stores` absent
      from `21-storage`, `20-cnpg`, `30-observability`; `foundation-vault` ships
      an Istio `DestinationRule` that belongs in `services-gateway`. No shipped
      profile is affected, which is why nothing caught them.
- [ ] **The only documented CAPI child on-ramp does not build** —
      `example-scaleway.yaml.example` declares a HelmRepository at a
      `source.toolkit.fluxcd.io` version that does not exist, and `edge-1.yaml`
      lacks the three `CHILD_BACKUP_*` vars its Kustomization declares required.
- [ ] **Seven markdown files in `OpenAether-apps` are French at an
      English-canonical name**, with no `.fr.md` twin, and `pick.py` mixes
      languages in its own `--help`. An accent regex is not enough — accent-free
      French escapes it.
- [ ] **`OpenAether-apps` still runs `gitleaks` bare**, and it is the repository
      the 2026-07-31 IPs and the Outscale account id actually leaked from. Copy
      `.gitleaks-envdata.toml`, the `leaks` job and `check-gitleaks-rules.sh` —
      a ruleset that matches nothing passes silently, and two rules here did.
- [ ] **Log in to a UI through the gateway.** The transport is done (HTTP 200
      through the gateway with our own intermediate); what is left is the
      Grafana↔Zitadel claim form, which needs `grafana-oidc` seeded and a human
      browser.

## Blocked on the world, not on us

Not work. Conditions. Do not re-investigate them from a desk.

- [ ] **Outscale: a Net that will not delete.** The LBU half is answered —
      a timeout inside Outscale's own load balancer service, request 399530
      closed, deploy into a fresh Net and it works (2026-08-20). What is left is
      what that hang created on 2026-08-19: a Net, its subnet and its internet
      service refusing deletion while the account held 0 VMs, 0 volumes, 0 load
      balancers, 0 public IPs, 0 NAT services and 0 NICs. Only Outscale can clear
      it; a second request is open and nothing here moves it.
- [ ] **`talos_machine` in the Talos provider will replace our orchestration** —
      its `image` argument upgrades when the running version differs, with
      `drain_on_upgrade` doing the cordon/uncordon. It is not in 0.11.0, the
      newest published stable and the one we pin; it lives in the 0.12.0-alpha
      line. When 0.12 stabilises, `rolling-replace` shrinks back to what only it
      can do: instance_type, disk and zone changes.
- [ ] **`talos_cluster_health` times out on healthy clusters** — OVH and Outscale
      only. Contained (`skip_health_check`, and the kubeconfig no longer depends
      on it). Filing needs `TF_LOG=DEBUG` on the failing read, `talosctl health`
      at the same moment, and one run with `skip_kubernetes_checks = true`.
- [ ] **Flux has no per-object Ready signal** — `gotk_reconcile_condition` is gone
      in Flux 2.8 and the kube-state-metrics `customResourceState` route produced
      a series exactly once. Asked upstream: kubernetes/kube-state-metrics#3052.
      Waiting — do not spend more time guessing at config.
- [ ] **`talos-image` is outside the emulated lane** — it stages images through
      object storage, and the Scaleway provider hardcodes the S3 endpoint in code.
- [ ] **Proxmox has never been applied for real** — needs the hardware. Plus
      Ansible host hardening, documented but absent from the repo.
- [ ] **OVH: a node can stay `ACTIVE` while dead.** `vp_reset` is virtio-pci's
      reset and `device_shutdown()` runs on every reboot path, so no Talos-side
      lever avoids it — only a hypervisor reset, which the recovery already
      prescribes. Detection is covered by `NodeUnreachable`. The root cause needs
      the incident to recur with the serial console attached.

## Traps worth remembering

One line each; the detail lives in the referenced file.

- **Talos drops the META `Upgrade` fallback only at `stage=running`** — a node
  that is Ready but stuck at `Booting` reverts on its next reboot, and
  `upgrade --wait` never returns. One unstartable extension is enough to hold the
  boot sequence open: check `talosctl services` before blaming the provider.
- **A create that times out leaves the resource tainted** — re-running DESTROYS
  what the provider was still building. Ask the provider's own API for the
  status, then `tofu untaint`; `task infra-apply` now prints the addresses and the
  command.
- **Credentials belong to the cloud that HOLDS the bucket**, not to the cluster's
  provider. Namespacing them the other way makes the variable name argue for the
  wrong value, and it gets one.
- **A version tag is not an image** — the schematic carries the extensions, and a
  new installer reference does not reinstall a running node. Compare the running
  schematic (`talosctl get extensions`), not the tag.
- **An OMI's backing snapshot is immutable** — the image must be replaced with
  the snapshot it is built on (`replace_triggered_by` + `create_before_destroy`),
  or the destroy order 409s and the account is left with no bootable image.
- **Never conclude from truncated output** — a `| tail` hid the servers that
  `purge-orphans` lists first, making a populated account look clean.
- **An empty server list is not an empty account** — 7 Scaleway block volumes
  billed for three days behind a clean-looking instance list. Check volumes.
- **A resource count driven by a phase variable is not idempotent** — gating
  `control_plane_count`/`worker_count` on `var.talos_bootstrap` zeroed them on
  every re-run and dropped `talos_machine_bootstrap` from state, which then got
  RECREATED, re-sending the bootstrap RPC to a live etcd.
- **Outscale `region` ≠ subregion** — `eu-west-2a` in the credentials secret
  builds an API host that does not resolve. Use `eu-west-2`.
- **Before translating a string, check that no code compares it** — `pick.py`
  identified its profiles by their French header, and `--check` went blind in
  silence.
- **A batch translation leaves half-translated blocks** — a French line between
  two English ones reads as finished and no linter catches it. Sweep, don't trust.
- **Three files can pin the same tool and only one be enforced** — helm was
  pinned in CI and in the renderer but not in `setup.sh`, invisible to everyone
  who already had helm 4.
- **A generated artifact drifts silently** — hence `task render-check` and
  `pick.py --check`. Prefer guardrails that compare over ones that assume.

### Traps — the apps layer, for the day Flux comes back

- **Flux substitution applies to a whole Kustomization render** — it blanks bare
  shell variables. Isolate `substituteFrom` in a brick with no script.
- **An operator and its own CRs need two Kustomizations** — a bundle with both is
  rejected at dry-run while the CRDs do not exist yet.
- **A failed Job is permanent under Flux** — it re-applies the same spec and never
  restarts a finished Job. A bootstrap Job must WAIT for its dependency.
- **A Kustomize `namespace:` overrides every resource**, including those of a
  referenced base. Validate the directory (`kubectl apply -k`), never a file.
- **`toServices: kubernetes` gets dropped** — the Service DNATs 443→6443 and
  Cilium enforces on the post-DNAT port. Use `toEntities: kube-apiserver`.
- **A CNP with no egress-to-S3 rule doesn't fail fast, it hangs** — CNPG's own
  instance pods need it for `barmanObjectStore`; a replica JOIN calling
  `restore_command` blocks forever instead of erroring.
- **Seed OpenBao app-DB secrets BEFORE the CNPG cluster's first `initdb`** —
  seeding late leaves the live Postgres role out of sync with the Secret.
- **`clusterctl move --dry-run` does not check providers** — it passes, and the
  real move fails. **`clusterctl init` does not install ORC** — CAPO v0.14 needs
  it, and without it network/LB/FIPs get created but no server ever does.
- **CAPO reuses an Octavia LB by NAME on the next deploy** — a leftover is not
  cruft, it silently breaks the redeploy. Re-verify the provider directly after
  a Kubernetes-level cascade.
- **`up == 0` only catches NODE-discovered targets**, and a rule on a metric
  nobody produces never fires and never says so (`task check-alerts`).
- **kube-state-metrics needs `honorLabels: true`**, or its labels become
  `exported_*` and every rule selecting on `namespace`/`pod` matches nothing.
- **A component's metrics port is often its service port** — vmselect serves
  queries and `/metrics` on 8481; check `up == 0` after touching an observability
  CNP. **A `VMRule` with no `VMAlert` is inert.**
- **`repeat_interval` must be strictly greater than `group_interval`** —
  Alertmanager sent one webhook in 11 min when both were 5m.
