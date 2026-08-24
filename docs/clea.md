# Cléa — what this repository pins, and whether the next version survives

🇫🇷 [Version française](clea.fr.md)

> The tool itself is documented where it lives:
> [`scripts/clea/README.md`](../scripts/clea/README.md). This page is only about
> how this repository uses it — what runs, when, and what a green report is
> allowed to claim.

## Why it exists

Renovate proposes bumps here and never auto-merges them. Two things it does not
do, and neither was covered by anything else:

- **It cannot say what it is not watching.** Nine of this repository's twenty-one
  version anchors were inert when Cléa was written: the comment was there, the
  bot never read it, and nothing said so. `task lint` now fails on that.
- **It does not install anything.** A bump that lands is a bump nobody watched
  install. `scripts/dev/feint.sh` carries the evidence: the pin moved to 0.10.0
  and every machine that had already run the lane kept 0.9.0, because presence
  was checked and version was not.

Cléa answers both, and reports daily. Renovate keeps proposing the bumps —
`.github/dependabot.yml` records what happens when two bots fight over one
dependency.

## What runs, and when

| lane | when | what it exercises |
|---|---|---|
| scan + coverage | daily, 04:17 UTC | every anchor read, resolved upstream, and compared against `renovate.json5` |
| tool probes | daily | cold install and in-place upgrade of each tool that moved, in a bare `ubuntu:24.04`, then `task lint`, `task render-check`, `task test-scripts` on the bumped tree |
| local cluster | weekly, Sunday 03:41 UTC | `task local-up` on the Talos and Kubernetes pair upstream publishes, then `task local-verify`, at 1 control plane + 1 worker |
| real cloud | never | by hand, by someone watching — see [`CONTRIBUTING.md`](../CONTRIBUTING.md) |

`.github/workflows/clea.yml` is the whole wiring. It carries no provider
credential and must fail rather than acquire one.

## Where the report is

One GitHub issue, labelled `clea`, **rewritten in place** every run — never a
new one. Its body also holds the previous run's state, in an HTML comment at the
end, which is how "this moved since yesterday" is computed without an artifact
store.

A probe pushes its branch `clea/probe/<dependency>` green **or** red: a red
branch is the reproduction, and deleting it would leave a report describing
something nobody can re-run. `clea prune` removes a branch once its bump has
landed on `main`.

## What a green report does not say

- **Nothing here has ever touched a real cloud.** A deploy on Scaleway, OVH or
  Outscale costs money and is run by hand.
- **A green probe means the tool installs and upgrades, and the repository's own
  checks still pass.** It does not mean the new version behaves the same on a
  running cluster. For Talos and Kubernetes, that is what
  [`upgrade.md`](upgrade.md) is for.
- **The weekly lane proves a pair boots on Docker at 1 + 1**, with Cilium up. It
  is not an HA test and it is not a rolling upgrade.

## Two things that will go red on purpose

- **A Cilium or Flux bump** moves a pin whose *output* is committed. The lane
  re-renders before running the gates, so the probe branch carries both halves —
  but if the render fails, `task render-check` is what says so.
- **helm and flux have no installer of their own**: they are steps inside
  `scripts/setup.sh`, which checks whether a binary is present and not which
  version it is. Their upgrade lane is expected to fail until that changes;
  `docs/backlog.md` holds the entry.

## Running it by hand

    task clea-scan                         # needs GITHUB_TOKEN
    python3 scripts/clea/clea.py coverage  # offline, and part of task lint

`task lint` runs `coverage`; `task test-scripts` runs Cléa's own assertions.

⚠️ GitHub disables a scheduled workflow after 60 days with no activity on the
repository. A silent Cléa is the failure this whole page is about: check the
report issue's date before trusting it.
