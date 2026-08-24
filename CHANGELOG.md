# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file used to document 1.0.0, 1.0.0-withdrawn and 1.1.0. Those tags and
releases were deleted from both repositories and none of them ever worked; a
changelog listing releases nobody can obtain is not a changelog. That history is
in git. 0.1.0 is the first entry describing something proven.

---

## [Unreleased]

### Added

- **`task talosconfig-new`** — issues a role-scoped talosconfig with a TTL
  (`os:reader`, 8 h by default) from the admin one, which the deploy hands out
  as `os:admin` valid a **year**, identical for every task and every person.
  It refuses to report success if the node grants roles other than those asked.
  ⚠️ Proven on the Docker lane only; the cloud path needs open tunnels and has
  never been run.
- **`task local-rbac`** — asks the Docker cluster whether Talos *enforces* those
  roles, which nothing here had ever established. Seven assertions, and each
  denial carries its admin control beside it so a broken command cannot read as
  a refused one. Measured 2026-08-24 on Talos v1.13.3: the node reports
  `Enabled: RBAC` with no `machine.features.rbac` anywhere in this repository,
  an `os:reader` config is refused a host read the admin config gets, and it
  cannot mint itself an `os:admin` one.

- **Cléa — a daily watch on what this repository pins, and a probe that installs
  the bump before anyone merges it.** `scripts/clea/` holds a generic engine
  (Python, standard library only, no knowledge of this project); `clea.toml`
  holds everything specific to it; `.github/workflows/clea.yml` runs it. Renovate
  keeps proposing the bumps — Cléa watches, probes and reports, and no lane of it
  can reach a cloud.
  - **Daily**: resolve every pin against upstream, then for each tool that moved,
    install it from cold and upgrade it over the old version in a bare
    `ubuntu:24.04`, then run `task lint`, `task render-check` and
    `task test-scripts` on the bumped tree. The upgrade half is the one that
    finds things: an installer that checks whether a binary exists, rather than
    which version it is, installs correctly once and refuses every upgrade after
    that — which is exactly what `scripts/dev/feint.sh` had done until
    2026-08-21.
  - **Weekly**: `task local-up` on the Talos and Kubernetes pair upstream
    publishes, then `task local-verify`. Real cloud stays manual.
  - **One report issue**, rewritten in place, which also carries the previous
    run's state so "this moved since yesterday" needs no artifact store.
  - **A heartbeat on the bot that proposes the bumps.** The scan records when
    `renovate[bot]` last opened a pull request, and crosses it with what Cléa
    found: a dependency behind *and* visible to the bot's own inventory, with no
    proposal for days, means the bot is not running. Silence on its own raises
    nothing — a bot with nothing to propose is silent and correct.
  - What it refuses to do: a datasource that answers nothing, a tree with no
    anchors and a writer that writes nothing all exit 1. An unauthenticated
    GitHub API answer is an error naming `GITHUB_TOKEN`, never "up to date" —
    60 requests an hour from a shared runner IP is what took `main` red on
    2026-08-13. Documented in [`docs/clea.md`](docs/clea.md).
  - **The probe found its first defect, and the same probe proved the fix.**
    `setup.sh` installed helm 4.2.4 from cold and left 4.2.3 in place when
    upgrading over it — the exact shape the upgrade lane exists to catch. After
    the fix, three lanes of three green. That loop, not the daily report, is
    what this is for.
  - **What the first real scan found**, running against live upstreams:
    `commitizen` pinned at 4.9.1 against 4.18.0 — nine minor versions, on one of
    the anchors that was inert — and the Cilium chart one patch behind at 1.20.0
    against 1.20.1. A Cilium bump was then walked through by hand: `task
    render-check` goes red on the stale manifest, the render lane closes it, and
    both go green. The GitHub datasources answered 403 in that session and were
    reported as failures, which is the behaviour that matters most: a
    datasource that did not answer is not a dependency that is up to date.

### Changed

- **Renovate moves from a six-hour weekly window to a daily one**, and
  `dependencyDashboard` becomes explicit. It has proposed nothing since its
  config landed on 2026-07-30 — its nine pull requests were created three hours
  *before* that file existed — and one measurement rules the schedule out as the
  explanation: helm 4.2.4 was published 2026-08-13, `setup.sh:225` pins 4.2.3,
  that anchor is one Renovate could always see, and the window of 2026-08-17
  passed four days later with nothing. The weekly window existed to batch noise;
  Cléa's daily report does that now, so it cost a week of latency and bought
  nothing. The dashboard is the visible heartbeat: issues were disabled on this
  repository until 2026-08-21, so Renovate had nowhere to report a configuration
  problem or its own state, and three weeks of silence looked exactly like three
  weeks of nothing to do.

### Fixed

- **`task security` could not be completed on a machine set up by
  `scripts/setup.sh`.** `install_checkov` tried pipx, then `python3 -m pip`,
  then apt — and Ubuntu 24.04 ships python3 with neither pip nor pipx, so the
  only branch left wanted sudo. A venv needs neither and carries its own pip;
  it now sits between them, and `install_yamllint` finally gets the
  "`pip3` is not always a binary" lesson its neighbour documented and never
  received.

- **`scripts/setup.sh` asked whether a tool was present, never which version it
  was** — so it installed the pin on a fresh machine and refused every upgrade
  afterwards, in silence, on every machine that had run it once. Found by the
  Cléa probe on a real bump: a cold install reached helm 4.2.4 while upgrading
  over 4.2.3 left 4.2.3. `check_cmd` now takes the pin and compares, bounded on
  both sides, for the three tools this file pins; the others have no version to
  compare against and pinning them is a separate decision.
  `scripts/dev/test-setup-checks.sh` guards it offline, so it does not need
  Docker to stay fixed.

- **The OpenTofu install asked the GitHub API which version was newest** —
  unauthenticated, 60 requests an hour from a shared IP, and it is the FIRST
  step, so a 403 there took the whole bootstrap down with `set -e` and nothing
  at all got installed. Exit 2 on a bare `ubuntu:24.04`, measured 2026-08-23.
  OpenTofu was the last tool here neither pinned nor verified; it now carries
  the same pin as `ci.yml`, passed to the installer explicitly, and
  `check-version-drift.sh` compares the two.

- **Nine of twenty-one version anchors were inert, and nothing said so.** The
  `# renovate:` comment was there and Renovate had never been told to read the
  file or the key, so the pin looked watched and was not: `go-task/task`,
  `terraform-linters/tflint`, `cloudnative-pg/cloudnative-pg`,
  `stephrobert/feint`, and `commitizen`, `gitleaks` and `helm` inside
  `ci.yml`. The two anchors in `Taskfile.yml` marked no version at all — the
  value moved into `talos-version.sh` and the anchors stayed behind. The six
  custom managers are now three, matched on the **shape** of a value rather than
  on the names of the keys that hold it, and written in the current
  `managerFilePatterns` spelling rather than the deprecated `fileMatch`.
  `task lint` now runs `clea coverage`, which fails on the next one.

- **`infrastructure/opentofu-local/variables.tf` carried no anchor at all**, so
  the credential-free lane drifted to Talos `v1.13.3` / Kubernetes `v1.35.3`
  against `v1.13.9` / `v1.36.3` in the cloud root. Anchored, so a proposal now
  reaches it; the pins themselves are not moved here because nothing has yet
  proven the newer pair boots — `docs/backlog.md` holds the entry and the weekly
  lane is what will close it.

---

### Security

- **`admin_ip` refuses to open the cluster to the internet.** The variable had
  no `validation`, so `["0.0.0.0/0"]` was accepted in silence — and it feeds
  bastion sshd *and* the 6443 LB ACL on all four providers at once. Behind that
  ACL sits a `system:masters` kubeconfig Kubernetes cannot revoke. Three rules
  now reject an empty list, an entry without a prefix (including the `YOUR_IP/32`
  of a copied example) and any `/0` — read from the prefix, so `198.51.100.7/0`
  is caught too. Nine cases in
  `cluster/tests/admin-ip-validation.tftest.hcl`; each rule was deleted in turn
  and the suite watched to go red before it was kept.
- **Admin access is documented as unrevocable where it is unrevocable.**
  [`docs/admin-access.md`](docs/admin-access.md) now says what a leaked
  kubeconfig costs, instead of leaving the reader to find out.


## [0.1.0] — 2026-08-20

> **This tag does not point at the commit first cut as 0.1.0.** That one,
> `421c1ee`, carried a real admin IP that had been serving as a test fixture in
> `check-gitleaks-rules.sh` since 2026-08-13 — found by reading the published tag
> as a stranger, which is what §9 of the release checklist is for. History was
> rewritten and the tag re-cut, twice: once on the purged history, once more to
> take in this record of it. No release was ever published under the first tag
> and nothing depended on it. GitHub still serves the old blob by direct SHA and
> the diff of the pull request that introduced it; only GitHub Support can remove
> those, and anyone who cloned before the rewrite keeps it.

**One Talos cluster, on one supported cloud, with one fixed foundation: Cilium.**
Infrastructure only — nothing above that layer. Start at
[`docs/first-cluster.md`](docs/first-cluster.md).

### Added

- **Every task is `<noun>-<verb>`**: `cluster-up`, `infra-plan`, `infra-apply`,
  `tunnels-up`, `cluster-verify`, `cluster-upgrade`, `cluster-idempotency`,
  `cluster-roll`, `infra-down`, `cluster-down`. Upgrades:
  [`docs/upgrade.md`](docs/upgrade.md). Day-1 access:
  [`docs/admin-access.md`](docs/admin-access.md).
- **An approval you cannot lose by accident.** `APPROVE=auto|ask` names *who*
  answers the question, never whether one is asked: every apply plans to a file
  and applies that file, and `tofu apply <saved plan>` does not prompt.
  `-auto-approve` is gone from the cloud path, CI included. Destroy always takes
  two commands and no flag collapses them.
- **State and artifacts encrypted client-side in S3**, with an optional replica
  on a second cloud. S3 credentials are namespaced by the cloud that *holds the
  bucket*, not by the cluster. Proven across providers: an encrypted tfstate at
  Outscale while the cluster ran on Scaleway.

### Validated

Measured on real accounts: Scaleway and OVH on 2026-08-19, Outscale on
2026-08-20. Versions were read back from the kubelets and from each node's own
Talos API, never from the tool that performed the upgrade.

- **Scaleway, from an empty account**: deploy in 8 min 50 for 72 resources,
  `cluster-verify` 11/11, idempotency 3/3, Kubernetes v1.36.2 → v1.36.3, Talos
  v1.13.7 → v1.13.8 confirmed by Talos itself on 6/6 nodes (`stage=running`,
  fallback dropped).
- **OVH**: the same five pillars — deploy, verify, idempotency, and both
  upgrades — the same versions, 11/11, idempotency 3/3.
- **Outscale**: the same five pillars again, measured the same way — deploy (51
  resources, then 17), `cluster-verify` 11/11, idempotency 3/3, the same two
  upgrades on 6/6 nodes. It had to go onto a **fresh Net**: see the known limits.
- **Idempotency is a property of the command.** Run `task cluster-up` once or a
  hundred times and you land in the state you asked for; the evidence is the
  command's own plan, which prints `No changes.` on a cluster that already
  matches. `task cluster-idempotency` adds the two assertions OpenTofu cannot
  make — the *same* nodes (name and `creationTimestamp`), and a kubeconfig that
  still reaches the apiserver — because an empty plan alone would not catch a
  node replaced underneath it.
- **A second Scaleway cycle on 2026-08-20**: `cluster-up`, `cluster-up`,
  `cluster-upgrade`, `cluster-up`, all four green, both re-runs applying nothing
  on all three roots. **Idempotency after an upgrade had never been checked**; it
  holds because `cluster-upgrade` writes the new pin back into the tfvars. Talos
  v1.13.8 → v1.13.9 on 6/6 nodes, and `cluster-verify` compared the running
  *schematic*, not just the version tag.
- **An upgrade is not seamless.** Longest apiserver outage 5 s on Scaleway (16
  failed probes out of 575), 7 s on OVH (9-10 out of ~540) and 8 s on Outscale.
  All three are *worse* than the best figures this project ever recorded (3 s,
  1 s and 1 s), and why has not been established. Plan for a gap.
  A later Scaleway run measured **2 s**, with the roll taking the etcd leader
  last and handing leadership over first. **That does not establish the fix**:
  that run moved Talos alone, while the 5 s run also moved Kubernetes, which
  restarts an apiserver per control plane by itself. Two workloads, two numbers
  that do not compare — quote the 5/7/8 figures.
- **333 offline assertions across 11 harnesses**, every one mutation-tested
  (`task test-scripts`). The emulated lane runs feint 0.10.0 against Scaleway provider
  2.81.0 — the same version the clusters run.

### Fixed

- **The shared schematic shipped `siderolabs/qemu-guest-agent`, and that one
  extension cost every upgrade.** It never starts on OVH or Outscale, whose
  images carry no `hw_qemu_guest_agent` device: the boot sequence never
  completed, Stage never became Running, the META Upgrade key was never dropped,
  and the next reboot reverted the upgrade the tool had just reported as
  successful. Root cause, not a workaround.
- **A failed purge no longer exits 0 saying "purge complete".** The teardown for
  this release found six Outscale resources, was refused on all six, and the
  script still reported success — the refusals were printed but never counted, so
  the exit code every caller reads said the account was clean. All three
  `purge-orphans` scripts now count failed deletions and end on one of three
  verdicts, the third being *N of M failed, NOT clean*.

### Removed

- **The staging CI lane.** 479 lines that never deployed anything: the workflow's
  one recorded run died for want of secrets that were never set, and part of it
  verified a platform this release disables (35 Flux Kustomizations). A weekly
  red that measures nothing teaches you to ignore red. 0.1.0 ships **no CI lane
  that deploys** — the credentialed rung is run by hand, by someone watching. The
  code is on the `archive/staging-lane` branch.

### Changed

- **`talos-image`'s "staging" bucket is now the "import" bucket.** This repository
  already spends that word on environments (`environment = "dev"`), and reading
  it as one here is what it cost. The variable is `import_bucket`, the bucket is
  `…-talos-import`, and the default is no longer a literal name with the project
  and the provider baked into it — it is empty, and refused where it is named.

### Known limits

Read these before deploying something that matters. Open items:
[the open issues](https://github.com/dis-bzh/OpenAether-infra/issues).

- **No Flux and no applications.** `deploy_flux` defaults to `false`. Flux is
  disabled, not amputated — the Talos module already reads an empty manifest as
  "no Flux", so turning it on moves no resource address — and it returns as a
  user choice in a later release. Everything it reconciles lives in
  `OpenAether-apps`.
- **No CAPI and no multi-cluster.** A management cluster is an optional overlay
  on top of this, never the entry point.
- **Outscale needs a fresh Net, and leaves one behind.** A load balancer that
  never left `provisioning` was diagnosed by Outscale as an internal timeout in
  their LBU service — support request 399530, now closed, with the instruction
  not to create another load balancer in that Net. One Net created before the
  fix still refuses deletion on a dependency no read returns; only the provider
  can clear it, and a second request is open for that.
- **No state lock on Outscale.** Its object store accepts a conditional write
  (`If-None-Match`) that Scaleway's and OVH's refuse, so `use_lockfile` is
  enabled on those two and deliberately not there — a lock that announces itself
  and holds nothing is worse than none. Two concurrent runs against an Outscale
  cluster's state are not stopped by anything.
- **Scaleway, OVH and Outscale are the clouds that were measured.** Proxmox has
  never been applied on real hardware; the local Docker rung proves
  `modules/talos` without credentials and nothing about a cloud. Anything else is
  code, not a claim.
- **Two release-checklist lines were not met, and are not ticked.** The OVH
  teardown was run once where the checklist asks for twice — an Octavia load
  balancer orphaned by one teardown was once silently reused by the next deploy,
  and only a second teardown proves the check that now covers it. And the
  Outscale purge is not clean: the pre-fix Net above is still there and no
  deletion is accepted for it.
- **One image bucket is orphaned by this release's own rename.** The old
  `…-talos-staging` still holds every QCOW2 it was given, on every cloud built
  from. `purge-orphans` lists it; emptying it is by hand.
- **`ovh.py` cannot tell a refused question from an empty account.** Its two
  siblings count refused calls and exit 2 when they found nothing but asked
  nothing; it has no such counter. A total auth failure crashes it rather than
  reporting clean, so this is a gap and not the same defect — but a partial
  refusal would shrink its findings in silence.
