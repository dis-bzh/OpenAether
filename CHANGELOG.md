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

### Fixed

- **Six gates were reporting green on something they had stopped checking.**
  Found by auditing what the pipeline actually constrains, and each one is
  reproduced in both directions — broken on purpose, watched go red, fixed,
  watched go green.
  - **`tflint` linted one directory out of fourteen.** The config lived in
    `cluster/`, and `tflint --recursive` resolves `.tflint.hcl` per directory —
    so the preset, the naming rule and the documentation rules applied nowhere
    else and the gate exited 0. Hoisting the file alone does **not** fix it (a
    parent config is never found either): `scripts/dev/tflint-all.sh` names the
    config through `TFLINT_CONFIG_FILE` and proves it loaded against a fixture
    that must draw a rule only this config enables — by rule *name*, since the
    default rules reject that fixture too and the exit code proves nothing.
    First finding on the newly-linted directories: `talos-image/variables.tf`'s
    `encryption_passphrase` had no description.
  - **`try()` hid a broken provider contract.** `cluster/main.tf`'s junction
    point read every provider output through `try(module.x[0].out, null)`, which
    cannot tell "this provider is inactive" from "this output does not exist".
    Measured: with `k8s_lb_ip` deleted from a provider module, `tofu validate`
    answered **Success!** and an apply would have yielded `null`, falling back to
    the literal `127.0.0.1` and failing at Talos, on a paid cluster. Now `one()`,
    which returns null at count 0 and refuses an undeclared attribute: the same
    tree answers `This object does not have an attribute named "k8s_lb_ip"`.
  - **Sixteen of the eighteen shell assertion harnesses could pass without
    asserting anything.** Thirteen ended on a bare `[ "$FAIL" -eq 0 ]` — true
    when the file died before its first assertion — and three more said the same
    thing in their own shape (`report()`, an `RC` accumulator, an `if`). All
    eighteen now carry the floor that `test-talos-image.sh` and
    `test-unattended.sh` already had. Worse, `test-endpoint-probe.sh` printed ✓ for a function that did not
    exist: `fn … && bad … || ok …` takes the `||` branch on rc 127 too. New
    `oa_require_fn` refuses to grade a function that is not defined.
  - **Two checks abstained in silence.** `render-bootstrap-manifests.sh --check`
    printed one warning mid-scroll when upstream was unreachable and `task
    preflight` still announced "every free rung passed"; it now fails, says
    *could not check* rather than *does not match*, and takes
    `RENDER_CHECK_ALLOW_OFFLINE=1` for a deliberate offline run — which
    `preflight` then reports as incomplete. `talos-image.sh` was worse: when the
    Factory answered with no schematic id in it (a rate limit, an error body — a
    *failing* curl aborts under `set -e`, so that was never the case), both the
    refusal and the reassurance were skipped and the run went straight to "image
    already up to date", one step from a billable publish. Now refused, or
    stated aloud under `TALOS_IMAGE_ALLOW_OFFLINE=1`, and covered by four new
    assertions in `test-talos-image.sh`.
  - **`provider-contract.md` had zero implementers on one of its rows.** It
    required a variable named `bastion_ssh_key` of type `string`; all four
    modules have always declared `bastion_ssh_keys` as `list(string)`, and a grep
    for the contract's name found exactly one hit in the repository — the
    contract's own line. This is the document `CLAUDE.md` and the
    `provider-module` skill both call the authority. The tables are now executed
    by `scripts/dev/check-provider-contract.sh`, by name and by type.
  - **The French detector could not read an HCL `description` heredoc**, so a
    whole French sentence sat mid-paragraph in an otherwise English block in
    `ovh/variables.tf` — in text `tofu` prints to the operator. The heredoc body
    is neither a comment nor a `description=` line, which is all the scanner
    looked at. Detector extended, sentence translated.

- **The French `admin-access` runbook was missing the fix that PR #14 landed for
  the English one**: the four CNPG/Longhorn seed paths and the warning above
  them. A French-speaking operator following it hit the silent auth failure that
  block exists to prevent — and both files carried the same last commit, which is
  exactly why "we commit them together" is not parity.

- **A tool could be the git author of a commit, and nothing looked.** The trailer
  check reads the message; GitHub builds a squash commit's `Co-authored-by` from
  the *branch* commits' authors, so by the time a message carries the trailer it
  is already on `main` — seventeen of the fifty commits there do. Measured on
  PR #106: its `0764f61` is authored by `Claude <noreply@anthropic.com>`. New
  `scripts/dev/check-commit-authors.sh`, run in CI on the PR range, which is the
  only place it can still be refused.

### Added

- **`task purge-orphans PROVIDER=… [APPLY=1]`.** `docs/release-checklist.md`
  already told the reader to run it; it did not exist. The scripts it wraps are
  the last sentence between a failed teardown and a bill, and they were reachable
  from prose only.
- **`flux_namespace` is validated.** The vendored `flux-install.yaml` creates
  exactly one namespace, `flux-system`, and every namespaced object in it points
  there. Any other value renders inlineManifests aimed at a namespace nothing
  creates — and Talos applies inlineManifests with no ordering and no namespace
  creation, so it fails on a paid cluster with every offline gate green. No
  schema validator can see it: `namespace: gitops` is valid YAML.

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
  - **The workflow's own first real run found what a bare-container probe
    could not.** Triggered by hand 2026-08-24 (`daily` lane): three probes —
    `commitizen`, `opentofu/opentofu`, `siderolabs/talos` — failed with
    "refusing to allow a GitHub App to create or update workflow… without
    `workflows` permission". All three are anchored (also) inside
    `.github/workflows/ci.yml`, and `GITHUB_TOKEN` cannot push a change to a
    workflow file in any repository — there is no `permissions:` grant for it.
    Two fixes: the Report job now cross-references the run's own job list, so
    a probe that fails before it can push is *named*, not silently absent from
    the report; and an optional `CLEA_WORKFLOW_TOKEN` secret (classic PAT,
    scope `workflow`), wired into both push sites with a clean fallback to the
    default token when unset, closes the gap for real where it is set.

### Changed

- **Six dependencies Cléa's first report ([#91](https://github.com/dis-bzh/OpenAether-infra/issues/91)) found behind upstream and probed green, bumped for real**:
  `go-task/task` 3.52.0 → 3.53.1, `cloudnative-pg/cloudnative-pg` 1.23.6 →
  1.30.0, `opentofu/opentofu` 1.12.5 → 1.12.6 (four anchors in `ci.yml` plus
  `setup.sh`), `cilium` 1.20.0 → 1.20.1 (chart re-rendered,
  `task render-check` green against the new manifest) and `commitizen` 4.9.1 →
  4.18.0. `helm/helm` and `fluxcd/flux2` stay put: the report's own verdict for
  both is "not probed" (they ride the weekly lane, `daily = false`), so there is
  nothing yet to act on. `stephrobert/feint` stays at 0.10.0: its probe failed
  outright — the installer at the current pin reported no version, so the
  upgrade lane had nothing to upgrade over — a defect in the installer, not
  something this bump could paper over.
  `task lint`, `task render-check`, `task test-scripts`, `task validate`
  (`cluster` and `talos-image`), `task test` and `task security` (checkov and
  gitleaks; `trivy` was not reachable from this sandbox) all green on the
  bumped tree.
  - **`kubernetes/kubernetes` v1.36.3 → v1.37.0, also reported probed green,
    is deliberately left out.** `task test` — not part of Cléa's own gate list
    — fails immediately on the bumped tree:
    `cluster/versions-guard.tf`'s Talos↔Kubernetes support matrix caps Talos
    1.13 at Kubernetes 1.36, and none of the three checks Cléa's daily lane
    does run (`task lint`, `task render-check`, `task test-scripts`) exercise
    that guard. The pairing is unproven, not confirmed broken — Cléa's weekly
    local-cluster lane is what would actually boot it, and the report says
    that lane "has not reported yet". `clea.toml`'s `[lane].repo` now also runs
    `task test`, so a probe branch hitting this guard is reported for what it
    is instead of green.

- **`talosctl` is pinned and checksum-verified** by
  `scripts/internal/install-talosctl.sh`, instead of piping `talos.dev/install`
  into a shell — the last tool in `setup.sh` that was neither, in a repository
  that checksums helm, task, tflint and feint. The version is not a new anchor:
  it is the cluster's own `talos_version` via `talos-version.sh`, so a
  workstation cannot end up with a CLI two patches from the fleet it talks to,
  and `siderolabs/talos` leaves `clea.toml`'s `[[unpinned]]` for a weekly probe
  row. It runs unconditionally rather than behind `check_cmd`, which probes with
  `talosctl version` — that prints the SERVER's tag too, so a stale client
  against a current cluster would satisfy the pin. Surfaced on a machine whose
  egress policy refuses `www.talos.dev`, where the old installer took the whole
  bootstrap down with it at step 2 under `set -e`.

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

- **Two tracked scripts were reachable from nothing**: `scripts/ops/ensure-capo-fip.py`
  (whose own docstring calls it "the only CAPO child resource created outside
  both OpenTofu and CAPI … the only one a teardown leaves behind and billing")
  and `scripts/ops/bastion-harden-check.sh`, a check nothing ever asked for.
  New `check-script-reachability.sh`, wired into `task lint`, requires every
  tracked script to be named by a task, a workflow, another script, or a
  document — a plain basename `git grep`, same shape as the reproduction in
  [#116](https://github.com/dis-bzh/OpenAether-infra/issues/116). Both scripts
  are kept: `ensure-capo-fip.py` is now documented in `docs/capi-bootstrap.md`
  / `.fr.md` (the CAPO floating-IP pitfall it exists to close), and
  `bastion-harden-check.sh` in `docs/release-checklist.md`'s "worth the extra
  spend" list.

- **The `gitleaks` pre-commit hook could not run at all in some sandboxes**,
  blocking every local commit. `.pre-commit-config.yaml` used the upstream
  `gitleaks` hook (`language: golang`), which pre-commit compiles from source
  on first use; that build panics inside `wasilibs/go-re2`'s WASM regex
  engine (`invalid table access`, in `wazero`) on at least one environment —
  reproduced across a full `go`-build-cache wipe and two Go toolchains, while
  the exact same version as an official release binary runs clean against the
  same tree. New `scripts/internal/install-gitleaks.sh` (pinned,
  checksum-verified, same shape as `install-task.sh`) installs that binary;
  `.pre-commit-config.yaml` now uses upstream's own `gitleaks-system` hook id
  against it instead of building one, with the `pass_filenames: false`
  upstream's `gitleaks-system` entry omits (without it pre-commit appends
  every changed file as a positional arg, and gitleaks' `git` subcommand
  accepts at most one). `check-version-drift.sh` now compares the two pins.
  [#126](https://github.com/dis-bzh/OpenAether-infra/issues/126)

- **A `--set` typo in `render-bootstrap-manifests.sh` was silent end to end.**
  `helm template` exits 0 on an unknown key (it just lands under another name
  in `.Values`), `task render-check` only diffs the render against itself, and
  `check-cilium-parity.py` skipped a `--set` key it could not resolve instead
  of flagging it — so a one-character typo (`hostNamespaceOnl` for
  `hostNamespaceOnly`) reached the cluster with nothing anywhere saying so.
  New `check-cilium-effective-config.py`, wired into `task render-check`,
  reads the EFFECTIVE settings the committed `cilium-config` ConfigMap
  carries rather than the flags that produced them; `check-cilium-parity.py`
  now fails when the production block does not set a `CHECKED` key at all,
  instead of silently treating that as "nothing to enforce".
  [#112](https://github.com/dis-bzh/OpenAether-infra/issues/112)

- **`outscale.py`'s purge never looked at leftover snapshots**, so a
  duplicate snapshot from a failed image build sat in the account while
  "account is clean" was true of everything the script asked and false of
  the account. It now lists them (`ReadSnapshots`) and refuses to claim clean
  while any are present — reported, never auto-deleted: same policy
  `scaleway.py` already documents for Talos build artifacts, and
  `fleet-down.sh`'s own "left standing on purpose" list. Images are
  deliberately still not enumerated — `ReadImages`' documented default scope
  can include Outscale's own public OMI catalogue, and scoping that safely
  needs verification against a live account, tracked separately as
  [#107](https://github.com/dis-bzh/OpenAether-infra/issues/107). Two paths
  used to say "clean" wrongly: an account with nothing else at all
  (`TOTAL == 0`), and — found while fixing the first — the successful
  `--apply` path itself, which said "resource(s) deleted, the account is
  clean" even with a snapshot still sitting there; a REFUSED `ReadSnapshots`
  call after a successful purge fell through the same way and is now
  reported as unconfirmed rather than silently clean.
  Refs [#71](https://github.com/dis-bzh/OpenAether-infra/issues/71) — the
  issue's own bar is real cloud; this closes the mocked-rung defect only.
- **`ovh.py`'s purge could not tell a refused endpoint from an empty account.**
  `scaleway.py` and `outscale.py` both count a refused call and refuse to
  claim "clean" on zero findings and zero reachable endpoints; `ovh.py` had no
  such counter, so a partial refusal — one endpoint answering 403 while the
  others still worked — crashed the run instead of being counted and
  continuing. It now shares the same `UNREACHABLE` counter and exit code.
  [#63](https://github.com/dis-bzh/OpenAether-infra/issues/63)
- **`converge-versions.sh` had no downgrade guard of its own.** It survived a
  Talos/Kubernetes downgrade attempt only by accident, on two layers it does
  not own (the talos provider's forced PKI replacement, and
  `secrets_prevent_destroy` turning that into a hard refusal — a variable that
  is explicitly false in `tofu test`). It now refuses a pin that is
  semver-lower than what the fleet runs, naming both, before calling either
  `infra-apply` or `cluster-roll`. [#90](https://github.com/dis-bzh/OpenAether-infra/issues/90)

- **`task local-down` refused to run on a clone that had only this repository.**
  `test-talos-local.sh` resolves `APPS_DIR` and exits 1 when it cannot find
  `OpenAether-apps/apps/flux/local` — before it reads `--destroy`, which never
  uses that directory. So the one command that cleans up after a failed deploy
  needed a second repository cloned, and refused exactly when containers,
  volumes and state were already on disk. Measured 2026-08-26 on the Docker
  lane; `--destroy` is now exempt from the check.

- **`task security` could not be completed on a machine set up by
  `scripts/setup.sh`.** `install_checkov` tried pipx, then `python3 -m pip`,
  then apt — and Ubuntu 24.04 ships python3 with neither pip nor pipx, so the
  only branch left wanted sudo. A venv needs neither and carries its own pip;
  it now sits between them, and `install_yamllint` finally gets the
  "`pip3` is not always a binary" lesson its neighbour documented and never
  received.

- **`command -v sudo` asks whether sudo EXISTS, not whether it can be USED**,
  and eight places asked it. On a workstation where `/usr/local/bin` is not
  writable and sudo wants a password, that answers yes, the installer then dies
  on a prompt nobody can answer, and `set -e` ends the bootstrap. The rule is
  now one function in `scripts/lib/common.sh` — `oa_sudo_usable`, `oa_bin_dir`,
  `oa_sudo_for` — used by `setup.sh` and by the four pinned installers instead
  of the same six lines repeated: passwordless sudo, or a terminal to be asked
  on, or neither, and a directory that does not exist yet is judged by its
  parent.

- **`install_tofu` preferred snap and brew, and neither can install a NAMED
  version.** `snap install --classic opentofu` serves whatever the channel
  holds, so on any machine with snap the pin was decorative — which is how this
  repository's own workstation ran 1.12.6 against a pinned 1.12.5. A pin an
  installer cannot honour is a pin that guarantees drift, and
  `check-version-drift.sh` now compares this one. Only the standalone installer
  remains: it takes `--opentofu-version`, and `--install-path` /
  `--symlink-path` let it install without root.

- **`infrastructure/opentofu-local/variables.tf` pinned a different Talos and
  Kubernetes than the cloud root** — `v1.13.3` / `v1.35.3` against `v1.13.9` /
  `v1.36.3`, drifted before either was anchored. The credential-free lane the
  README calls the best first step was exercising a pair that is not the one
  that ships. Now pinned equal. Measured on the shipped default topology
  (3 control planes + 3 workers, Docker): all six nodes Ready, Cilium on 6/6,
  `task local-verify` 6/6 — versions read from the cluster itself, not the tool
  that deployed it (`kubectl get nodes` → `v1.36.3` on all six; `talosctl
  version` against the control plane's own API → server tag `v1.13.9`).
  Closes [#87](https://github.com/dis-bzh/OpenAether-infra/issues/87). The
  cloud root's own pin — `v1.13.9`, one patch past what this repository's
  real-cloud evidence table covers — is untouched and unrelated.

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
  reaches it; the pins themselves are not moved here. Measured 2026-08-24 on the
  Docker lane: the newer pair (`v1.13.9` / `v1.36.4`) boots, 6/6 on
  `task local-verify`. Unifying the two roots and a real-cloud upgrade are
  [#87](https://github.com/dis-bzh/OpenAether-infra/issues/87).

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
- **358 offline assertions across 11 harnesses**, every one mutation-tested
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
