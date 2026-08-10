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
task feint-plan   PROVIDER=scaleway    # plan the REAL cluster root, no credentials
task feint-apply  PROVIDER=outscale    # apply/destroy cycle on the reduced fixture
task feint-record PROVIDER=scaleway    # rank what our module calls and no pack serves
task feint-test                        # both providers, plan + apply
task feint-down
```

## Three lanes, because one cannot do all three jobs

**`feint-plan` — the real `cluster` root, plan only.** Real modules, real
provider, `envs/feint-<provider>.tfvars.example`. It cannot go further than
`plan`, and what stops it is now a short list rather than a long one:

- **Scaleway**: the module always builds a public gateway and IPAM reservations,
  and neither is served. Unchanged since 0.5.0 — the Scaleway pack did not move.
- **Outscale**: only the load balancers. Feint 0.6.0 took the pack from 31 routes
  to 72, so security groups, public IPs, the internet service, the NAT service,
  route tables and NICs all work now; `CreateLoadBalancer` is still declined.

The root declares a partial S3 backend, so the lane drops a local-backend
`*_override.tf` in and removes it on exit.

**`feint-apply` — `infrastructure/opentofu-feint/`, a real CRUD cycle.** A
separate root (same idea as `infrastructure/opentofu-local`) carrying the same
shapes over the subset the emulator does serve: init → validate → plan → apply →
**empty second plan** → destroy, with existence and disappearance both re-read
from the API rather than from the state. See its
[README](../infrastructure/opentofu-feint/README.md).

**`feint-record` — measure the wall instead of arguing about it.** `feint proxy`
sits between the provider and the emulator and writes one redacted JSON object
per exchange; `feint transcript` then ranks the operations no pack serves,
most-called first. The apply behind it is *expected* to fail, on the first
unserved call — everything up to that point is what gets recorded. Current
output, reproducible with the commands above:

| Provider | Called, served by nobody | Calls |
|---|---|---|
| Scaleway | `/ipam/v1/regions/fr-par/ips` (501) | 2 |
| Scaleway | `/lb/v1/zones/fr-par-1/ips` (404) | 2 |
| Scaleway | `/vpc-gw/v2/zones/fr-par-1/ips` (404) | 1 |
| Outscale | `/api/v1/CreateLoadBalancer` (404) | 2 |

Upstream is the emulator here, not the cloud, and that is a constraint rather
than a shortcut: a client that signs the host it was configured with — the
Terraform provider does — cannot be recorded against a real cloud through a
reverse proxy, since the cloud checks the signature against its own name and
answers 401. So this measures *what we call that is missing*, not what the real
cloud would answer with.

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

Pinned to **Feint 0.6.0** (`scripts/dev/feint.sh`). What this lane still cannot
carry, all recorded in [`backlog.md`](backlog.md):

| Not exercised | Why |
|---|---|
| Outscale load balancers | `CreateLoadBalancer` is declined; only `ReadLoadBalancers` is mounted. The last thing between this lane and a full apply of the Outscale module. |
| Scaleway LB, public gateway, IPAM reservations | Unserved, and the Scaleway pack did not change in 0.6.0. |
| Scaleway root volume type | The module asks `sbs_volume`; the emulator answers `b_ssd`, and provider 2.80 refuses an explicit `b_ssd`. Honouring `sbs_volume` sends the provider to `block/v1`, which is not mounted. |
| `data.outscale_images` | Segfaults the provider: `data_source_outscale_images.go:289` dereferences `*image.BlockDeviceMappings` with no nil guard and the catalogue omits it. Reported upstream, still open on 0.6.0 — which is why the tfvars pin `image_id`. |
| Tags on route tables and internet services | `CreateTags` knows four identifier prefixes (`vpc-`, `subnet-`, `i-`, `key-`), so tagging an `igw-` or an `rtb-` is refused on a resource it has just created. The production module tags both. |

`outscale_volume_link` used to be on this list and is not any more: 0.6.0 mounts
the `LinkVolumeVmIds` filter its wait depends on.
