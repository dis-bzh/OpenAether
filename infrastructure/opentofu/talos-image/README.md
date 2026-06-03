# OpenAether — Talos image builder (decoupled)

Builds the Talos boot image **once per Talos version** from the
[Talos Image Factory](https://factory.talos.dev) and publishes it into a cloud
provider, so the cluster apply can use it. Kept in a **separate state** from the
clusters — the image has its own lifecycle and is reused by every cluster/env on
that provider. Building an image **never touches deployed cluster infra**, so it
works the same before or after a cluster exists.

```
schematic.yaml ──POST──▶ Factory schematic ID
                              │
              ┌───────────────┼────────────────────────────┐
              ▼ scaleway       ▼ ovh (openstack)            ▼ outscale
  download·zstd·qemu→qcow2   download·zstd·qemu→qcow2        (not yet)
              │                │
   Object Storage→snapshot    Glance image (region-wide)
   →Instance Image /zone      → image_id (UUID)
   (lookup by name)           (set as image_id in cluster tfvars)
```

## State

State lives on the **target provider's** S3 — its own bucket per provider
(`s3-openaether-<provider>-talos-image` / `talos-image.tfstate`), so building one
provider's image never disturbs another's. The state bucket (and the Scaleway
staging bucket) are **auto-created** by `scripts/talos-image.sh`.

## Prerequisites

- **Compute creds** for the target provider: `SCW_*` (scaleway), `OS_*` (ovh,
  OpenStack), `OSC_*` (outscale).
- **S3 creds** for the target provider's Object Storage (state + staging),
  namespaced so you keep all providers in `.env.sh` at once:
  - `SCW_AWS_ACCESS_KEY_ID` / `SCW_AWS_SECRET_ACCESS_KEY` — default to `SCW_*` (Scaleway S3 == API keys).
  - `OVH_AWS_ACCESS_KEY_ID` / `OVH_AWS_SECRET_ACCESS_KEY` — **separate** keys (`openstack ec2 credentials create`), *not* `OS_PASSWORD`.
  - `OUTSCALE_AWS_ACCESS_KEY_ID` / `OUTSCALE_AWS_SECRET_ACCESS_KEY` — default to `OSC_*` (OOS == API keys).
  - (plain `AWS_*` still works as a fallback.)
- `TF_VAR_encryption_passphrase` (≥32 chars).
- Local CLI tools: `curl`, `zstd`, `qemu-img`, `aws` (installed by `task setup`).

## Usage

```bash
task talos-image PROVIDER=scaleway                 # or ovh ; [VERSION=v1.13.3]
# equivalent: ./scripts/talos-image.sh scaleway v1.13.3
```

- **Scaleway** — the cluster looks the image up by **name**
  (`tofu output image_name` → `talos-scaleway-amd64-<version>`), already the
  default in the `envs/*.tfvars.example`.
- **OVH** — Glance gives a UUID: `tofu output image_id` → put it as `image_id` in
  the cluster `envs/<env>/<cluster>.tfvars`.
- **Outscale** — the OMI registration gives an `ami-…` id: `tofu output image_id` →
  put it as `image_id` in the cluster `envs/*.tfvars`.

## Customising the image

Add official system extensions in [`schematic.yaml`](schematic.yaml) (e.g.
`siderolabs/qemu-guest-agent`) and re-run. The schematic ID is deterministic, so
the build is reproducible and auditable.

## Providers

| `PROVIDER` | Status | Mechanism |
|---|---|---|
| `scaleway` | ✅ implemented | qcow2 → Object Storage → block snapshot import → Instance Image (per zone) |
| `ovh` | ✅ implemented | qcow2 → Glance (`openstack_images_image_v2`, local upload — region-wide) |
| `outscale` | ✅ implemented | `nocloud` raw → OOS staging → `outscale_snapshot` import (pre-signed URL) → OMI (`outscale_image`) |
