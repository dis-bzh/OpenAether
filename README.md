# OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Cloud Management Platform (CMP).

## Version

**v0.4.0** — Multi-cloud infrastructure with hub/spoke GitOps, cross-provider failover, and client-side-encrypted dual-store backups. Management cluster validated end-to-end on Scaleway, OVH, and Outscale; full cloud lifecycle re-run clean. Ready for external testers (not yet 1.0).

## Architecture

```
Management Cluster (Hub) — Scaleway HA (3 zones)
  ├── ArgoCD (hub mode — manages all spoke clusters via ApplicationSet)
  ├── OpenBao (secrets management — HA Raft)
  ├── Keycloak + CloudNativePG (identity)
  ├── VictoriaMetrics (observability aggregator)
  └── Traefik (Gateway API)
          │
     ┌────┴──────────────────────┐
     ▼                           ▼
SCW Workload Cluster     OVH Workload Cluster     Outscale Workload Cluster
(spoke — client apps)    (spoke — client apps)    (spoke — client apps)
```

**Design principle:** The management cluster is NOT in the client data path. If the management cluster is temporarily unavailable, client workloads continue running unaffected. Management plane RTO: ~30 min (cross-provider failover) → Phase 4 target: <5 min.

## Layer Status

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.3 (Immutable) | ✅ |
| **CNI** | Cilium 1.19.2 (WireGuard) | ✅ |
| **GitOps** | ArgoCD v3.3.2 (hub/spoke) | ✅ |
| **Gateway** | Traefik v3.0 (Gateway API) | 🚧 Phase 2 |
| **Identity** | Keycloak 26.0 + CloudNativePG | 🚧 Phase 2 |
| **Secrets** | OpenBao 2.2.0 (Vault fork) | 🚧 Phase 2 |
| **Observability** | VictoriaMetrics v1.102.0, Grafana 11.2.0 | 🚧 Phase 2 |
| **Autoscaling** | KEDA v2.15.1 | 🚧 Phase 2 |
| **Policy** | Kyverno v1.12.0 | 🚧 Phase 2 |

## Cloud Provider Support

Management cluster validated end-to-end (Talos bootstrap → Cilium → ArgoCD) on **all three** providers.

| Provider | Status | Region | Notes |
|----------|--------|--------|-------|
| **Scaleway** | ✅ Management validated | fr-par (3 AZs) | HA control plane, public gateway egress, full networking stack |
| **OVH** | ✅ Management validated | EU-WEST-PAR (OpenStack) | Octavia LB, floating IPs, router SNAT egress, private network |
| **Outscale / Numspot** | ✅ Management validated | eu-west-2 | LB, NAT-service egress, public/private subnets, VPC |

## Repository Structure

```
OpenAether/
├── infrastructure/
│   └── opentofu/                    # All Infrastructure as Code
│       ├── cluster/                 # Cluster root (management + workload)
│       │   ├── main.tf, backup.tf, backend.tf, variables.tf, outputs.tf
│       │   ├── envs/                # Per-cluster config (<kind>-<provider>)
│       │   │   ├── management-{scaleway,ovh,outscale}.tfvars(.example)
│       │   │   ├── workload-{scaleway,ovh,outscale}.tfvars(.example)
│       │   │   └── failover-{scaleway,ovh,outscale}.tfvars(.example)
│       │   └── tests/               # OpenTofu unit tests (26 tests total)
│       ├── talos-image/             # Image builder root (one-off per version)
│       │   ├── main.tf, backend.tf, variables.tf
│       │   └── schematic.yaml       # Image Factory schematic
│       └── modules/                 # Shared modules (both roots)
│           ├── talos/               # Cluster secrets, config, bootstrap
│           ├── providers/
│           │   ├── scw/             # Scaleway (reference implementation)
│           │   ├── ovh/             # OVH / OpenStack
│           │   └── outscale/        # Outscale / Numspot
│           └── talos-image/
│               ├── scaleway/        # qcow2 → snapshot → instance image
│               ├── ovh/             # local qcow2 → Glance
│               └── outscale/        # raw → OOS → snapshot → OMI
├── apps/                            # Kubernetes manifests (GitOps)
│   ├── base/                        # Provider-agnostic service definitions
│   ├── overlays/
│   │   ├── management/              # Management cluster apps
│   │   ├── workload-base/           # Workload cluster base apps
│   │   ├── local/                   # Local development
│   │   └── prod/                    # Production (legacy)
│   └── bootstrap/                   # ArgoCD bootstrap + ApplicationSet
│       └── overlays/prod/
│           ├── root-appset.yaml     # ApplicationSet (multi-cluster)
│           └── local-cluster-secret.yaml
└── scripts/
    ├── setup.sh
    ├── render-bootstrap-manifests.sh
    ├── register-spoke.sh            # Register spoke cluster in ArgoCD hub
    ├── failover-management.sh       # Stand up management on another cloud (~30 min)
    ├── ensure-buckets.sh            # Create the per-cluster backup buckets (idempotent)
    ├── tf-backend.sh                # Derive the S3 backend config from a cluster's tfvars
    ├── backup-state.sh              # Replicate the encrypted tfstate to the -backup store
    ├── backup-artifacts.sh          # gpg-encrypt + upload kube/talosconfig (OpenTofu local-exec)
    └── test-local-stack.sh          # Full local validation (no cloud needed)
```

## Quick Start

### Prerequisites

```bash
./scripts/setup.sh                  # installs tofu, talosctl, kubectl, task, helm, yamllint…

# For CLOUD deploys only — load your credentials (see .env.example for the full,
# documented list of variables). Local Docker testing needs none of this.
cp .env.example .env.sh             # then edit it with your provider creds
source .env.sh                      # .env.sh is git-ignored
```

### Local cluster (Docker — no cloud, no credentials)

Brings up a real **3 control plane + 2 worker** Talos cluster in Docker — etcd
quorum, Cilium, ArgoCD, and the GitOps `ApplicationSet → Application` chain — on
the **same production `modules/talos/`** used in the cloud. Best first step.

```bash
task local-test                     # full deploy + verify (3 CP + 2 workers)
task local-status                   # etcd members + nodes + ArgoCD
task local-argocd                   # ArgoCD UI → https://localhost:8080
task local-down                     # tear down (containers + volumes + state)
```

See [infrastructure/opentofu-local/README.md](infrastructure/opentofu-local/README.md) for details.

### Deploy the Management Cluster (cloud)

```bash
source .env.sh                      # provider creds + TF_VAR_encryption_passphrase

# Configure your cluster (copy the template, then edit). Real envs/*.tfvars are
# git-ignored; only the *.tfvars.example are versioned.
cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
# Edit: admin_ip, bastion_ssh_keys, image_name/image_id, s3_primary_*/s3_replica_*

# Phase 0 — build the Talos image once per version (separate state, reused by all clusters)
task talos-image PROVIDER=scaleway

# Phase 1 — ensures the backup buckets, derives + inits the backend, provisions the
# infra, replicates the state. PROVIDER defaults to scaleway (also ovh, outscale).
task infra-management PROVIDER=scaleway

# Phase 2 — opens the SSH tunnels (from state), bootstraps Talos + ArgoCD, and pushes
# the client-side-encrypted backups (kube/talosconfig + state replica).
task management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

### 🚧 Deploy a Workload Cluster

```bash
cp infrastructure/opentofu/cluster/envs/workload-ovh.tfvars.example \
   infrastructure/opentofu/cluster/envs/workload-ovh.tfvars   # then edit (image_id, admin_ip…)

task infra-workload PROVIDER=ovh
task workload PROVIDER=ovh KEY=~/.ssh/yourkey
task register-spoke CLUSTER=openaether-ovh-prod PROVIDER=ovh   # register in the ArgoCD hub
```

### 🚧 Cross-provider failover — second management on another cloud

```bash
# If your primary management provider is unavailable, stand one up elsewhere:
task failover PROVIDER=ovh
# RTO: ~30 minutes. Client workloads are unaffected during recovery.
```

### Static checks (no cloud, no Docker)

```bash
./scripts/test-local-stack.sh        # tofu fmt/validate/test + kustomize + talosctl + yamllint
./scripts/test-local-stack.sh --fast # skip talosctl gen
```

## Security

| Control | Implementation |
|---------|----------------|
| No public IPs on cluster nodes | VPC-only, bastion SSH tunnel |
| Bastion SSH | Dedicated unprivileged user, key-only (root login & passwords disabled) |
| State encryption | Client-side AES-GCM + PBKDF2 (OpenTofu `encryption{}`) before S3 |
| Artifact backup encryption | Client-side gpg AES-256 (authenticated) + S3 SSE on top |
| Backup replication / DR | State + artifacts mirrored to a `-backup` store (prod: a different provider, separate creds) |
| Kubernetes API access | LB ACL restricted to `admin_ip` |
| Talos API access | SSH tunnel only (port 50000, never on LB) |
| Inter-node encryption | Cilium WireGuard |
| Secrets management | OpenBao (Vault fork, open source) |

## Roadmap

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **3** | OVH + Outscale active, ArgoCD hub/spoke, cross-provider failover | ✅ Done |
| **4** | DNS failover (ExternalDNS + k8GB), OpenBao auto-unseal | ⏳ Planned |
| **4b** | Warm standby management on OVH (<5 min RTO) | ⏳ Planned |
| **5** | Service catalogue (Kratix / Backstage) | ⏳ Planned |
| **6** | Active-active management (Cilium ClusterMesh) | ⏳ Planned |

## License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source: **https://github.com/dis-bzh/OpenAether**
