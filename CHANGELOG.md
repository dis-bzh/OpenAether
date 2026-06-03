# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.3.4] — 2026-06-03

### Fixed — Outscale management cluster end-to-end (3/3 providers live)

Brought the Outscale management cluster to a working Talos bootstrap, completing
validated **management** deployments on all three providers (Scaleway ✅ ·
OVH ✅ · Outscale ✅). Fixes, in the order they surfaced:

- **Control-plane NIC** — control planes attach to the subnet directly; Outscale's
  CreateVm rejects a dedicated NIC together with the VM's security groups.
- **Bastion SSH user** — Outscale's official OMIs default to the `outscale` login,
  not `ubuntu`; `bastion_user` is now mapped per provider (scaleway/ovh/outscale).
- **Node internet egress** — the module had only an Internet Gateway, which 1:1-NATs
  instances that own a public IP. The cluster nodes have none, so NTP and the
  etcd/Kubernetes image pulls timed out and the bootstrap hung. Added a **NAT
  service** in an AWS-style two-subnet layout (private nodes → NAT, public
  bastion/NAT/LB → IGW), mirroring the Scaleway public-gateway / OVH router SNAT.
- **Tunnel host key** — `talos-tunnels.sh` clears the stale `known_hosts` entry
  before opening; a re-created bastion keeps its EIP but gets fresh host keys, which
  otherwise failed every tunnel with a host-key mismatch.
- **Worker certSANs** — the worker machine config now includes `127.0.0.1` (like the
  control plane), required because Phase 2 reaches every node through an SSH tunnel
  on localhost (was failing TLS verification with "valid for <node IP>, not 127.0.0.1").

### Fixed — ArgoCD installed in the management-gitops namespace

`render-bootstrap-manifests.sh` now kustomizes the upstream ArgoCD install into
`${ARGOCD_NAMESPACE:-management-gitops}` (+ the Namespace, + the ClusterRoleBinding
subjects, which kustomize doesn't rewrite on its own). The namespace-agnostic
upstream manifest, injected as a Talos inlineManifest, was landing in `default` —
so ArgoCD watched `default` while the root app lived in `management-gitops` and the
root Application never reconciled. Affects every provider's bootstrap.

### Added

- **`task destroy-management PROVIDER=…`** — symmetric with `destroy-workload`.

### Changed

- Provider names spelled out everywhere (`scw` → `scaleway`) in docs/env templates,
  consistent with the bucket/image naming convention.
- OVH defaults: region `EU-WEST-PAR` (3-AZ), node/bastion flavor `b3-8`.
- Outscale bastion downsized to `tinav5.c2r2p2`.

---

## [0.3.3] — 2026-06-03

### Changed — repository structure (Option A)

All OpenTofu code is now under `infrastructure/opentofu/`:

```
infrastructure/opentofu/
  cluster/        ← cluster root (was infrastructure/opentofu/ top-level)
  talos-image/    ← image builder root (was infrastructure/talos-image/)
  modules/        ← shared modules (unchanged)
```

No task names changed for the user. The `task talos-image`, `infra-management`,
`management`, `infra-workload`, `workload`, `failover` tasks still work identically —
only the `dir:` and script paths were updated internally.

### Changed — Talos image bucket naming

`task talos-image PROVIDER=scaleway` now uses bucket `s3-openaether-scaleway-talos-image`
(was `s3-openaether-scw-…`), consistent with OVH/Outscale which already used
the full provider name. Fixes a Scaleway async-delete bucket collision.

### Added — Talos image build for Outscale

`task talos-image PROVIDER=outscale` is now implemented:
`nocloud-amd64.raw.zst` → OOS staging → `outscale_snapshot` import (pre-signed URL,
`snapshot_size` in bytes, ~16 min) → `outscale_image` (OMI).

Key fixes along the way: AWS CLI v2.23+ trailing checksum (`when_required`),
`snapshot_size` in bytes (not GiB), pre-signed URL for Outscale auth, explicit
provider creds via `TF_VAR_outscale_*` (API == OOS keys for Outscale).

Validated images: Scaleway ✅ · OVH ✅ · Outscale ✅.

---

## [0.3.2] — 2026-06-02

### Changed — backup & DR storage model (client-side encryption + dual store)

Every DR artifact now lives in **two** object stores — a **primary** (the
cluster's own provider) and a **replica** (`-backup`; in prod a *different*
provider, different creds) — and is **client-side encrypted** before it ever
reaches storage.

### Added

- **Client-side encrypted artifact backups** — `scripts/backup-artifacts.sh`
  encrypts talosconfig/kubeconfig with **gpg `--symmetric` AES-256** (authenticated,
  hardened S2K) using the same `encryption_passphrase` as the tfstate, then uploads
  to the primary **and** replica stores with S3 SSE on top. Replaces the previous
  SSE-only (server-side) backup.
- **tfstate replication** — `scripts/backup-state.sh` copies the already
  client-encrypted state (AES-GCM) to the `-backup` store after each apply (the
  backend only flushes state on apply exit, so this is a post-apply step). Wired
  into the cluster tasks + a standalone `task backup-state`.
- **Per-cluster encrypted state** — the S3 backend is now **partial**
  (`backend.tf`); its bucket/key/region/endpoint are **derived from the cluster's
  tfvars** by `scripts/tf-backend.sh` (single source of truth, so dev/prod never
  drift — no separate backend file). Each cluster gets its own state following
  `s3-<project>-<provider>-tfstate-<env>` (key `<cluster_name>.tfstate`).
  Artifacts follow `s3-<project>-<provider>-<role>-<env>`.
- **Cross-provider backup creds** — `BACKUP_AWS_ACCESS_KEY_ID` /
  `BACKUP_AWS_SECRET_ACCESS_KEY` for the replica store (default to the primary
  `AWS_*` in dev). `setup.sh` now installs/checks `gpg` + `jq`.
- **Bucket auto-provisioning** — `scripts/ensure-buckets.sh` derives the bucket
  names from a cluster's tfvars and creates any that are missing (idempotent),
  wired into `task infra-management` / `infra-workload` before `tofu init` (the
  S3 backend doesn't create its own bucket). Only the **state primary** bucket is
  required pre-`init` (fatal); the backups are best-effort and never block deploy.
- **Provider in the bucket names** — convention is now
  `s3-<project>-<provider>-{tfstate|<role>}-<env>(-backup)` (provider explicit,
  derived from the active provider), consistent across management and workload.
- **Provider-generic management & failover** — `task infra-management` /
  `management` now take `PROVIDER` (scaleway/ovh/outscale), like the workload tasks.
  Full env matrix added: `management-{scaleway,ovh,outscale}`,
  `failover-{scaleway,ovh,outscale}` (each a `.tfvars.example`).
  A `failover-*` cluster is the **cross-provider failover** (a second management
  on another cloud) — distinct from the everyday recovery of re-applying your own
  `management-<provider>` on the same provider.

### Renamed

- **`drp-*` → `failover-*`** to match what it is: a *second* management cluster on
  a **different** cloud (provider loss), not the everyday disaster recovery (which
  is just re-applying your own `management-<provider>`). `scripts/drp-management.sh`
  → `scripts/failover-management.sh`, `task drp` → `task failover`,
  `envs/drp-*` → `envs/failover-*`.

### Removed

- Dead `aws` provider + `backup_s3_{endpoint,region,bucket}` variables (the
  backup path is CLI-only now). New inputs: `s3_primary_{endpoint,region}` and
  `s3_replica_{endpoint,region}`; bucket names are derived from the convention.

### Documented

- Backup/restore (DR) procedure — decrypting a backed-up artifact with the same
  passphrase; recovering state from the `-backup` store.

---

## [0.3.1] — 2026-06-01

### Validated — first end-to-end cloud deployment (Scaleway)

The management cluster stack came up on Scaleway (3 control planes + 2 workers,
Cilium, ArgoCD, GitOps), exercising the two cloud-only Talos resources that local
Docker can't: `talos_machine_configuration_apply` (gRPC) and
`data.talos_cluster_health`. Changes that got it there:

### Added

- **Block-storage Talos image** — the image builder now imports the QCOW2 as a
  `scaleway_block_snapshot` per zone and builds a block-backed image (boots
  current-gen PRO2/POP2; l_ssd/DEV1 is a deprecated, zone-limited dead-end).
- **Auto SSH tunnels for Phase 2** — `scripts/talos-tunnels.sh` reads node IPs
  from the state and opens one tunnel per node via the bastion; wired into the
  `management` / `workload` tasks (`task close-tunnels` to tear down).
- **CLI-based encrypted S3 backup** (`terraform_data` + `aws s3 cp`, SSE-S3) for
  talosconfig/kubeconfig — replaces `aws_s3_object`, which hits a `version_id`
  plan-inconsistency bug on S3-compatible stores.

### Fixed / Security

- **Bastion hardening** — dedicated unprivileged `bastion` SSH user (root login
  and password auth disabled) instead of `root`.
- **Bastion public-IP routing** on the NAT'd VPC — a root systemd unit stops the
  VPC-pushed default route from hijacking the bastion's inbound SSH.
- **Single-cloud applies** no longer require other providers' credentials
  (OpenStack `auth_url` placeholder when OVH is inactive).
- **Plan-known node counts** — gate count/for_each on `node_distribution` counts
  rather than apply-unknown private IPs (Phase 1 and Phase 2 both plan cleanly).
- **Phase-2 connectivity** — feed the talos module per-node tunnel endpoints
  (CPs `127.0.0.1:5000+i`, workers `5010+i`).

### Documented

- Manual teardown procedure (`state rm` the PKI-protected secrets +
  `-var talos_bootstrap=false` to skip the tunnel-bound health check).

---

## [0.3.0] — 2026-05-30

### Added — Local 3-CP Talos test harness (Docker)

- **`infrastructure/opentofu-local/`** — standalone OpenTofu root (no S3 backend) that drives the **production `modules/talos/`** to stand up a real **3 control plane** Talos cluster in Docker.
- **`modules/providers/local/`** — Docker-based provider (terraform_data + Docker CLI, no Docker provider dependency): N containers on a dedicated `10.5.0.0/24` network with static IPs, `--read-only`, `PLATFORM=container`, the full Talos volume set, and config injected via `USERDATA`. Implements the provider contract with a node-IP / host-endpoint split (`127.0.0.1` port mappings for WSL2).
- **`modules/talos/` enhancements (backward-compatible, cloud unchanged):**
  - `config_delivery` (`apply` cloud / `userdata` Docker) — Docker uses USERDATA injection per the Talos platform docs (maintenance-apply reboot-loops in containers).
  - `control_plane_endpoints` / `worker_endpoints` — reach nodes via port mappings while keeping container IPs as node identity (etcd/certSANs).
  - `container_mode` — omits `machine.install` and enables `hostDNS.forwardKubeDNSToHost`.
  - `health_check_timeout`, `skip_kubernetes_health_checks`, `skip_health_check` — robustness knobs.
  - New outputs `control_plane_machine_configs` / `worker_machine_configs` (consumed for USERDATA).
- **`scripts/test-talos-local.sh`** — single-command E2E: config gen → 3 USERDATA containers → etcd quorum bootstrap → kubeconfig → Cilium (3 nodes) → ArgoCD → ApplicationSet.
- **`render-bootstrap-manifests.sh --local`** — simplified Cilium (no WireGuard, no kube-proxy replacement) for Docker.
- **Taskfile** `local-*` tasks.
- **Validated end-to-end**: 3 nodes `Ready` on Kubernetes v1.35.3, **3-member etcd quorum**, Cilium CNI on all nodes, tofu-retrieved kubeconfig, ArgoCD running, and the ApplicationSet generating the management cluster's Application.
- **Coverage**: 7 of 8 `modules/talos/` resources are exercised locally; only `talos_machine_configuration_apply` and the `talos_cluster_health` data source are cloud-only (both for legitimate platform/networking reasons).

### Added

**Multi-cloud CMP infrastructure (Phase 3):**
- **OVH / OpenStack module** — complete networking stack (private network, router, Octavia LBs, floating IPs, bastion)
- **Outscale / Numspot module** — VPC, subnets, load balancers, public IPs, bastion
- **Provider-agnostic junction point** — `coalesce()` selects the active provider; adding a new provider requires only implementing the contract
- **`cluster_role` variable** — `management` or `workload` routes ArgoCD to the correct overlay
- **Per-cluster environment templates** — `envs/management-scaleway.tfvars.example`, `envs/workload-{scaleway,ovh,outscale}.tfvars.example`, `envs/drp-ovh.tfvars.example` (copy to the real `*.tfvars`, which stays git-ignored)
- **Single-provider validation** — `check` block prevents accidentally activating multiple providers in one apply

**GitOps multi-cluster:**
- **ArgoCD ApplicationSet** — replaces single root Application; automatically deploys the correct overlay to each registered cluster
- **Management cluster overlay** — `apps/overlays/management/` (OpenBao, Keycloak, VictoriaMetrics, etc.)
- **Workload cluster overlay** — `apps/overlays/workload-base/` (Traefik, ESO, Kyverno, KEDA, storage)
- **Local cluster secret** — management cluster registers itself in ArgoCD hub on bootstrap

**Operational tooling:**
- **`scripts/register-spoke.sh`** — registers a workload cluster in ArgoCD hub after provisioning
- **`scripts/drp-management.sh`** — automated DRP procedure; rebuilds management cluster on fallback provider (~30 min RTO)
- **`scripts/test-local-stack.sh`** — full local validation (OpenTofu tests + kustomize builds + talosctl + yamllint) with no cloud credentials required
- **Taskfile** — new tasks: `deploy-management`, `deploy-workload`, `bootstrap-workload`, `register-spoke`, `drp`

**Testing (26 unit tests):**
- `tests/scaleway.tftest.hcl` — 9 tests (SCW module, provider contract, multi-provider activation)
- `tests/talos-config.tftest.hcl` — 10 tests (certSANs, bootstrap logic, version format, cluster role)
- `tests/provider-contract.tftest.hcl` — 7 tests (junction point behavior, all 3 providers, safe defaults)

**CI enhancements:**
- OpenTofu tests run all 3 test suites
- Kustomize build validation for all 6 overlays
- Talos config generation and validation via `talosctl`

### Changed

- `node_distribution` variable extended with OVH/Outscale-specific optional fields (`flavor_name`, `availability_zones`, `network_name`, `bastion_image_id`)
- `outputs.tf` — all outputs are now provider-agnostic; added `active_provider` and `cluster_role`
- `argocd-root-app.yaml.tftpl` — now points to `apps/bootstrap/overlays/prod/` instead of a single overlay path
- `apps/overlays/local/` — removed deprecated Linkerd (replaced by Cilium Service Mesh, Phase 4)
- YAML lint config — added ignore patterns for vendor/generated files; relaxed sequence indentation rule

### Fixed

- `apps/base/namespaces/` — missing `kustomization.yaml` (kustomize build was failing)
- `apps/base/kyverno-policies/` — missing `kustomization.yaml`
- `apps/base/openbao/statefulset.yaml` — indentation errors
- `apps/base/openbao/httproute.yaml` — indentation errors
- `apps/base/traefik/rbac-gateway.yaml` — lines exceeding 120 chars
- Grafana — disabled anonymous admin access (was `GF_AUTH_ANONYMOUS_ENABLED=true`)

### Updated (versions)

| Component | Before | After |
|-----------|--------|-------|
| VictoriaMetrics | v1.93.0 | v1.102.0 |
| Grafana | 10.0.0 | 11.2.0 |
| OpenBao | 2.0.0 | 2.2.0 |
| KEDA | v2.12.0 | v2.15.1 |
| Kyverno | v1.10.0 | v1.12.0 |
| kubectl (Kyverno CronJob) | v1.28.2 | v1.33.0 |
| busybox (storage) | unpinned | 1.36.1 |

---

## [0.2.0] — 2026-02-01

- **Secure Remote Management**: Encrypted S3 Backend for Tofu state (Client-Side Encryption, AES-GCM).
- **Automated SSE-C Backups**: Secure artifact backup (`kubeconfig`, configurations) to S3.
- **Zero-Trust Networking**: Refactored LB ACLs (admin IP + NAT GW hairpinning).
- **Scaleway Deployment**: First provider deployed and validated in HA environment.
- **Zero-Local Policy**: No persistent local configuration files.

### Infrastructure

- Scaleway: Security Groups with zonal segmentation.
- Scaleway: Hybrid zone support for `DEV1-S` / `PRO2` instance types.

---

## [0.1.0] — 2025-12-31

- Multi-provider architecture (Outscale, Scaleway)
- Talos Linux v1.9.1, Pulumi (Go) IaC
- Cilium CNI auto-deployment
- Taskfile automation
- GitOps structure prepared (`apps/`)
