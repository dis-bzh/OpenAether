# Emulated cloud (Feint) — testing Scaleway and Outscale without an account

🇫🇷 [Version française](emulated-cloud.fr.md)

[Feint](https://github.com/stephrobert/feint) is a local emulator of the
Scaleway, Outscale and Exoscale APIs: one static Go binary on
`127.0.0.1:4599`, no account, no bill. This repository points the **real**
Scaleway and Outscale provider binaries at it, so the provider talks real HTTP to
a real API with no credentials in scope.

That is one step past what we had. `task validate` checks syntax; `task test`
mocks the provider and never leaves the process; `task local-up` exercises
`modules/talos` on Docker but no cloud provider module at all. Outscale in
particular had **no apply-mode coverage of any kind** before this.

Feint's own coverage and limits are documented upstream — read them there rather
than here, they move: [`docs/limits.md`](https://github.com/stephrobert/feint/blob/main/docs/limits.md).

## Running it

```bash
task feint-up                          # start the emulator (installs the pinned binary if absent)
task feint-plan  PROVIDER=scaleway     # plan the REAL cluster root, no credentials
task feint-apply PROVIDER=outscale     # apply/destroy cycle on the reduced fixture
task feint-test                        # both providers, both lanes
task feint-down
```

## Two lanes, because one cannot do both jobs

**`feint-plan` — the real `cluster` root, plan only.** Real modules, real
provider, `envs/feint-<provider>.tfvars.example`. It cannot go further than
`plan`: the module always builds a Scaleway public gateway and IPAM
reservations, and Outscale security groups, public IPs, an internet service, a
NAT service, route tables and load balancers — the emulator serves none of them.
The root declares a partial S3 backend, so the lane drops a local-backend
`*_override.tf` in and removes it on exit.

**`feint-apply` — `infrastructure/opentofu-feint/`, a real CRUD cycle.** A
separate root (same idea as `infrastructure/opentofu-local`) carrying the same
shapes over the subset the emulator does serve: init → validate → plan → apply →
**empty second plan** → destroy, with existence and disappearance both re-read
from the API rather than from the state. See its
[README](../infrastructure/opentofu-feint/README.md).

## The guard

Feint's own repository once created a billable server because a redirection
evaluated to empty and the client fell back to the operator's stored profile.
Every official cloud client does that. So:

- `emulator_api_url` (and the fixture's `endpoint`) **only accept a loopback
  URL** — a remote value is a validation error, not a warning;
- `scripts/dev/feint.sh` refuses a non-loopback endpoint and unsets every
  `SCW_*` / `OSC_*` variable before running anything;
- when the emulator is active the provider blocks **pin** fake credentials, so
  the provider cannot go looking for real ones.

## What it proves, and what it does not

**Proves**: the provider configuration is accepted and the whole graph resolves
with no credential; a real create/read/update/delete cycle over the served
subset; and, through the empty second plan, that every attribute sent comes back
identical — which is where an invented or dropped field surfaces.

**Does not prove that a real deployment works.** The emulator has no inventory:
an image id or machine type that exists nowhere is *accepted*, where the real
cloud refuses. No load balancer, no gateway, no quotas, no latency, state
transitions are instant, and authentication is never verified. Real cloud remains
the only proof of a deployment; this catches wiring regressions before spending.

## Known gaps

Three production attributes this lane cannot carry today, all recorded in
[`backlog.md`](backlog.md): the Scaleway root volume type, `outscale_volume_link`,
and `data.outscale_images` — which segfaults the Outscale provider, because
`data_source_outscale_images.go:289` dereferences `*image.BlockDeviceMappings`
with no nil guard and the emulator omits that field.
