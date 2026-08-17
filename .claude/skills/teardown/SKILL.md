---
name: teardown
description: Destroying an OpenAether cluster and proving the account is clean — fleet-down, purge-orphans, and the per-provider traps that have left resources billing. Use when finishing a real-cloud run, when a destroy fails partway, or before changing anything the teardown path calls.
---

# Tearing down a cluster

The general discipline is the global `cloud-teardown` skill — read it for *why*.
This is the OpenAether commands and the traps this project has actually met.

## The sequence

```
task down PROVIDER=<p> -- --force-no-edges --yes
python3 scripts/ops/purge-orphans/<p>.py
```

The bare `--` is not optional: without it Task keeps the flags for itself.

**`--force-no-edges` is required on every 1.0.0 cluster**, and the reason is
structural rather than incidental. `fleet-down.sh` refuses to destroy the
management until it has enumerated CAPI child clusters, because a child that
outlives its management bills for ever. On a pure-infra cluster the CAPI CRDs are
legitimately absent, so that query can never succeed — the flag is how the
operator asserts there are no children. Anything that invokes the bare form (a
workflow, a README line) will refuse and leave the cloud running.

## Per-provider, learned the expensive way

- **Outscale — never verify with the EC2-compatible endpoint.** `aws
  ec2 describe-instances` against `fcu.<region>.outscale.com` returned **0
  instances while the native `ReadVms` returned 7 running**. Use the native API;
  `scripts/ops/preflight-quotas.py` already carries the caller.
- **Outscale — a wedged load balancer pins the Net**, and then every `tofu
  destroy` dies on "the subnet is in use, it has NICs" or on a read the provider
  cannot reconcile. The order that works is the dependency order, by hand,
  through the native API.
- **The destroy races the provider.** Deletions propagate asynchronously;
  `fleet-down.sh` retries three times with a pause (`DESTROY_ATTEMPTS`,
  `DESTROY_BACKOFF`) and still fails at the end if the resource is genuinely
  stuck. Do not raise the retries to make a real failure green.
- **Local Docker cluster:** `task local-down`.

## Left standing on purpose

Talos images and their snapshots (rebuilding costs about an hour on Outscale),
keypairs, and the S3 buckets — state, artifacts, backups. Deleting a state
bucket destroys the ability to restore. `fleet-down.sh` step 3 lists them by
name rather than removing them; that report is the deliverable, not noise.

## Proving it

`scripts/ops/verify-provider-clean.py` and the purge scripts ask the provider,
not the state file. Report the counts. A session is not finished until something
that queries the account says zero.

## Before you touch it

`scripts/dev/test-teardown.sh` is the harness, and it found the `--force-no-edges`
defect on its first run. Run it after any change to `fleet-down.sh`, and make a
new assertion fail on purpose before trusting it.
