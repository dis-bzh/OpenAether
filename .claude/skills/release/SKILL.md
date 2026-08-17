---
name: release
description: How to cut an OpenAether release — what has to be proven first, what a version number is allowed to assert, and what the notes must admit. Use when tagging, writing release notes, or deciding whether a release is ready.
---

# Cutting a release

The authority is `docs/release-checklist.md` in OpenAether-infra — run it, do
not summarise it. It is not linked relatively here because this skill is shared
with OpenAether-apps, which has no such file. This is only what the checklist cannot tell you.

## A version number is a claim

A tag asserts that something was proven. 1.0.0 was cut before deploy,
idempotency and upgrade had ever been run on the three clouds — the very things
it was meant to certify — and had to be withdrawn. Decide what the number
asserts, prove exactly that, then tag.

**Say which rung each claim reached.** Mocked, emulated, real cloud once by hand,
or unattended and repeated. "Proven at the real-cloud rung on Scaleway, open on
OVH" is a release note. "Proven" is a hope.

## The two repositories are independent

Infra no longer pins an OpenAether-apps tag: the `envs/*.tfvars.example` carry
`git_ref = "refs/heads/main"`, so there is no ordering constraint between the
two and no matching-version rule to honour. If a release ever reintroduces a
pin, the pinned ref has to exist before the thing pointing at it — and that
constraint belongs back in this file the same day.

## Order, and why

1. Everything in `§0`–`§7` of the checklist, on real clouds, **torn down**, with
   `scripts/ops/purge-orphans/` clean on each. Nothing left billing.
2. A GitHub release, with notes that name the limits.
3. Re-clone the published tag into a scratch directory and read it as a stranger:
   licence, changelog, examples, **no real tfvars in the archive** — and check
   that the quick start's commands exist and its values are accepted.

## The notes must admit what is not fixed

Someone upgrading a cluster that matters will hit the open items before they hit
the features. Name them, say what happens, and point at `docs/backlog.md`. A
release note that only lists what works is a release note that will be believed
about the rest.

## Withdrawing a tag

Only when nothing was published under it — no release, no dependent tag — and
only by saying so in the changelog and the release notes. Anyone who fetched the
old tag gets different content under the same name; that is not something to
discover, it is something to be told.

**Reusing a number that has already carried a published release is a different
act, and a heavier one.** It rewrites what a version means for anyone who
already has it. If the scope has changed enough to justify starting over, the
honest move is usually a new number — a major bump for a breaking change of
scope, or dropping back below 1.0.0 to say plainly that the interface is not yet
settled. Reusing the same number twice teaches people the numbers mean nothing.
