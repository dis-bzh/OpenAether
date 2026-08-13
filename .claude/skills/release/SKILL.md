---
name: release
description: How to cut an OpenAether release — what has to be proven first, the order of the two repositories, and what the notes must admit. Use when tagging, writing release notes, or deciding whether a release is ready.
---

# Cutting a release

The authority is `docs/release-checklist.md` in OpenAether-infra — run it, do
not summarise it. It is not linked relatively here because this skill is shared
with OpenAether-apps, which has no such file. This is only what the checklist cannot tell you.

## A version number is a claim

1.0.0 was tagged before deploy, idempotency and upgrade had ever been run on the
three cloud providers — which is what it was meant to certify. It had to be
withdrawn and re-cut. Decide what the number asserts, then prove that, then tag.

## Order, and why

1. Everything in `§0`–`§7` of the checklist, on real clouds, **torn down**, with
   `scripts/ops/purge-orphans/` clean on each. Nothing left billing.
2. Tag **OpenAether-apps first**, then OpenAether-infra. Infra pins
   `refs/tags/<version>` of apps, so the ref has to exist before the thing that
   points at it. The twelve `envs/*.tfvars.example` carry that pin — they are part
   of the release, not documentation about it.
3. A GitHub release on each, with notes that name the limits.
4. Re-clone the published tag into a scratch directory and read it as a stranger:
   licence, changelog, examples, and **no real tfvars in the archive**.

## The notes must admit what is not fixed

Someone upgrading a cluster that matters will hit the open items before they hit
the features. Name them, say what happens, and point at `docs/backlog.md`. A
release note that only lists what works is a release note that will be believed
about the rest.

## Withdrawing a tag

Only when nothing was published under it — no release, no dependent tag — and
only by saying so in the changelog and the release notes. Anyone who fetched the
old tag gets different content under the same name; that is not something to
discover, it is something to be told. Do it once. Doing it twice teaches people
the numbers do not mean anything.
