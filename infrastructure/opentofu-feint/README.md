# OpenAether — Emulated cloud fixture (Feint)

A real `apply` / `destroy` cycle against a **local emulator** of the Scaleway and
Outscale APIs — no account, no credentials, no bill. Driven by
`task feint-apply PROVIDER=scaleway|outscale`.

What this lane proves, what it does not, and the exact coverage wall:
**[`docs/emulated-cloud.md`](../../docs/emulated-cloud.md)**. Read that first —
this file only explains why the root exists separately.

> No backend (local, disposable state). Renders the bastion cloud-init from the
> shared `../opentofu/modules/providers/_shared/` template.

## Why a separate root rather than the cluster root

The cluster root cannot apply against the emulator. It always builds a Scaleway
public gateway and IPAM reservations, and Outscale security groups, public IPs,
an internet service, a NAT service, route tables and load balancers — none of
which the emulator serves. Pointing it at Feint is still useful, but only as far
as `plan`: that is `task feint-plan`, on the real root.

So this root carries the same *shapes* over the subset the emulator does serve,
which is what makes a create/read/update/delete cycle possible at all. It is
**not** a deployable cluster and never will be: no Talos, no LB, no bootstrap.

## What the runner asserts

`scripts/dev/feint.sh apply <provider>` does init → validate → plan → apply →
**second plan must be empty** → destroy, and then:

- after apply, the machines are re-read **from the API**, not from the state — a
  state file that agrees with itself is not evidence that anything exists;
- the empty second plan is the real assertion: it holds only if every attribute
  the provider sent comes back identical, which is where an invented or dropped
  field surfaces;
- after destroy, the same ids (captured *before* the destroy) are asked for
  again. On Outscale a deleted VM stays readable as `terminated`, on the real API
  as here, so the check reads state rather than counting rows.

## Three production attributes this fixture cannot carry

Each is a real emulator gap, recorded in `docs/backlog.md`:

| Not exercised | Why |
|---|---|
| Scaleway root volume type | The module asks for `sbs_volume`; the emulator answers `b_ssd` whatever was requested, and provider 2.80 refuses an explicit `b_ssd`. Declaring either is a permanent diff or an error, so the type is left to the API. |
| `outscale_volume_link` | The provider waits for the link through `ReadVolumes` with a `LinkVolumeVmIds` filter, which the emulator refuses — by design, since it applies a filter or rejects it rather than silently returning everything. |
| `data.outscale_images` | Segfaults the provider: `data_source_outscale_images.go:289` dereferences `*image.BlockDeviceMappings` with no nil guard, and the emulator omits that field. |
