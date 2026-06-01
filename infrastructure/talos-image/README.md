# OpenAether — Talos image builder (decoupled)

Builds the Talos boot image **once per Talos version** from the
[Talos Image Factory](https://factory.talos.dev) and publishes it into a cloud
provider, so the cluster apply can simply look it up by name. Kept in a
**separate state** (`talos-image.tfstate`) from the cluster — the image has its
own lifecycle and is reused by every cluster on that provider.

```
schematic.yaml ──POST──▶ Factory schematic ID
                              │
                              ▼  scaleway-amd64.raw.zst
                    download · zstd -d · qemu-img → qcow2
                              │
                              ▼
                Object Storage ─▶ snapshot (import) ─▶ Instance Image   ┐ per zone
                                                          "talos-scaleway-amd64-v1.13.3"  ┘ (fr-par-1/2/3)
```

> Scaleway images are **zonal**. The module publishes the same-named image into
> every zone in `scaleway_zones` (default `fr-par-1/2/3`) so an HA cluster spread
> across zones finds it everywhere. The QCOW2 is uploaded once (the bucket is regional).

## Prerequisites

- Scaleway API keys exported (`SCW_ACCESS_KEY`, `SCW_SECRET_KEY`,
  `SCW_DEFAULT_PROJECT_ID`) **and** the matching S3 vars
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` = the same Scaleway keys).
- `TF_VAR_encryption_passphrase` (≥32 chars).
- Local CLI tools: `curl`, `zstd`, `qemu-img`, `aws`. Installed by `task setup`, or manually:
  `sudo apt install -y zstd qemu-utils` + AWS CLI via `sudo snap install aws-cli --classic`
  (Ubuntu 24.04 dropped `awscli` from apt) or the official v2 bundle.

## Usage

```bash
cd infrastructure/talos-image
tofu init
tofu apply -var target_provider=scaleway -var talos_version=v1.13.3
# or: task talos-image PROVIDER=scaleway

tofu output image_name   # -> talos-scaleway-amd64-v1.13.3
```

Put that `image_name` in the cluster env (it already matches the
`envs/*.tfvars.example` convention `talos-scaleway-amd64-<version>`), then run
the cluster apply in `../opentofu`.

## Customising the image

Add official system extensions in [`schematic.yaml`](schematic.yaml) (e.g.
`siderolabs/qemu-guest-agent`) and re-apply. The schematic ID is deterministic,
so the build is reproducible and auditable.

## Providers

| `target_provider` | Status | Import mechanism |
|---|---|---|
| `scaleway` | ✅ implemented | qcow2 → Object Storage → snapshot import → image |
| `ovh` (OpenStack) | ⏳ next | `openstack_images_image_v2` **web_download** straight from the Factory URL (no upload) |
| `outscale` | ⏳ next | qcow2/raw → OOS → OMI import task |
