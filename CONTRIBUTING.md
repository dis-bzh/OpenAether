# Contributing

## Setup

    task setup      # installs OpenTofu, talosctl, kubectl, Task, pre-commit
    pre-commit install

## Before opening a PR

    task lint         # tofu fmt, yamllint (infrastructure/ + .github/workflows/ + root configs), tflint
    task validate ROOT=cluster
    task validate ROOT=talos-image
    task test

All four run in CI too — a PR can't merge until they're green (see the required
checks on `main`).

Before touching the Flux DAG in the sibling `OpenAether-apps` repo:

    task apps-validate

## Conventions

- English for code, comments, commit messages and docs (`*.md` is canonical,
  `*.fr.md` is a translation, never the source).
- Comments explain the *why*, not the *what* — 1-3 lines, no incident narratives.
- Open work items live in `docs/backlog.md`, not scattered TODOs — read it before
  starting non-trivial work, and drop an entry once it's done (that's what git
  history is for).
- Dependency bumps (OpenTofu providers, Talos, Kubernetes, Cilium, Flux, CI
  actions, pre-commit hooks) are proposed by Renovate and never auto-merged —
  review the diff, especially anything labeled `needs-regen` (the pinned version
  bumped but a vendored manifest needs regenerating by hand) or
  `vendored-manifest`.

## Pull requests

`main` requires a PR with all CI checks green — including for maintainers, no
direct pushes. No mandatory reviewer count yet (small team), but PRs stay open
for review during that window regardless.
