# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> Un cluster Talos idempotent sur n'importe quel environnement — local (Docker),
> on-prem (Proxmox) ou cloud (Scaleway/OVH/Outscale) — avec pour seul socle figé
> **CNI (Cilium) + Flux**. Tout le reste se pioche dans `OpenAether-apps`.

## Version

**v0.4.0+** — Socle Talos modulaire multi-provider (recentrage : voir `CLAUDE.md`
et `CHANGELOG.md [Unreleased]`). Management validé end-to-end sur Scaleway, OVH
et Outscale ; local Docker validé (3 CP + workers) ; Proxmox code-complet
(jamais appliqué sur matériel réel). Backups tfstate/artifacts chiffrés client,
double store. Le multi-cloud actif-actif est abandonné ; le hub/spoke CAPI est
une **surcouche optionnelle** (cf. `OpenAether-apps/apps/clusters/`).

## Architecture

```
Un cluster Talos autonome (socle figé : Cilium + Flux)
  └── pioche modulaire dans OpenAether-apps (scripts/pick.py) :
      OpenBao, ESO, cert-manager/PKI, Istio ambient, gateway, CNPG,
      Longhorn, observability, Zitadel, Kyverno, backups restic…

Surcouche OPTIONNELLE — cluster de management (CAPI pioché) :
  Management (hub) ──CAPI+Talos──▶ clusters clients (kubeception)
                    ──Flux kubeConfig──▶ Cilium+Flux injectés,
                    puis chaque enfant réconcilie SON profil git (gitception)
```

**Design principle:** The management cluster is NOT in the client data path. If the management cluster is temporarily unavailable, client workloads continue running unaffected (each child runs its own Flux).

## Layer Status

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.3 (Immutable) | ✅ |
| **CNI** | Cilium 1.19.2 (WireGuard) | ✅ |
| **GitOps** | Flux v3.3.2 (hub/spoke) | ✅ |
| **Gateway / Mesh** | Istio 1.24.2 (ambient mesh + Gateway API) | 🚧 Phase 2 |
| **Identity** | Zitadel 10.0.2 (v4.14) + CloudNativePG | 🚧 Phase 2 |
| **Secrets** | OpenBao 2.2.0 (Vault fork) | 🚧 Phase 2 |
| **Observability** | VictoriaMetrics v1.102.0, Grafana 11.2.0 | 🚧 Phase 2 |
| **Autoscaling** | KEDA v2.15.1 | 🚧 Phase 2 |
| **Policy** | Kyverno v1.12.0 | 🚧 Phase 2 |

## Provider Support

Même contrat pour tous (`modules/providers/provider-contract.md`) — le stack
Talos/cluster est provider-agnostique. Statut détaillé : `docs/deployment-test-matrix.md`.

| Provider | Status | Region / cible | Notes |
|----------|--------|----------------|-------|
| **Scaleway** | ✅ Management validated | fr-par (3 AZs) | Implémentation de référence ; rolling-replace exercé live |
| **OVH** | ✅ Management validated | EU-WEST-PAR (OpenStack) | Octavia LB, floating IPs, router SNAT egress, private network |
| **Outscale / Numspot** | ✅ Management validated | eu-west-2 | LB, NAT-service egress, public/private subnets, VPC |
| **Proxmox (on-prem)** | 🧪 Code-complet, unit-testé — **jamais appliqué en réel** | PVE single/multi-host | VIP Talos (pas de LB managé), NAT/DNAT nftables hôte, prérequis manuels (cf. `modules/providers/proxmox/README.md`) |
| **Local (Docker)** | ✅ Validé (`task local-test`) | WSL2/Docker | 3 CP + workers, quorum etcd, Cilium+Flux — preuve creds-free de `modules/talos` |

## Repository Structure

```
OpenAether-infra/
├── infrastructure/
│   └── opentofu/                    # All Infrastructure as Code
│       ├── cluster/                 # Cluster root (management + workload)
│       │   ├── main.tf, backup.tf, backend.tf, variables.tf, outputs.tf
│       │   ├── envs/                # Per-cluster config (<kind>-<provider>)
│       │   │   ├── management-{scaleway,ovh,outscale,proxmox}.tfvars(.example)
│       │   │   ├── workload-{scaleway,ovh,outscale}.tfvars(.example)
│       │   │   └── failover-{scaleway,ovh,outscale}.tfvars(.example)
│       │   └── tests/               # OpenTofu unit tests (incl. proxmox)
│       ├── talos-image/             # Image builder root (one-off per version)
│       │   ├── main.tf, backend.tf, variables.tf
│       │   └── schematic.yaml       # Image Factory schematic
│       ├── opentofu-local/          # Local Docker root (reuses modules/talos)
│       └── modules/                 # Shared modules (both roots)
│           ├── talos/               # Cluster secrets, config, bootstrap
│           ├── providers/           # provider-contract.md = the contract
│           │   ├── scw/             # Scaleway (reference implementation)
│           │   ├── ovh/             # OVH / OpenStack
│           │   ├── outscale/        # Outscale / Numspot
│           │   ├── proxmox/         # Proxmox VE (on-prem, VIP Talos, no managed LB)
│           │   └── local/           # Docker containers (WSL2-aware)
│           └── talos-image/
│               ├── scaleway/        # qcow2 → snapshot → instance image
│               ├── ovh/             # local qcow2 → Glance
│               ├── outscale/        # raw → OOS → snapshot → OMI
│               └── proxmox/         # nocloud image on the PVE host
└── scripts/
    ├── setup.sh
    ├── lib/common.sh                # Shared helpers (tfvars parsing, S3 creds)
    ├── bootstrap/                   # Cluster lifecycle (run once or rarely)
    │   ├── render-bootstrap-manifests.sh
    │   ├── talos-image.sh
    │   ├── talos-tunnels.sh
    │   ├── register-spoke.sh        # Register spoke cluster in Flux hub
    │   └── failover-management.sh   # Stand up management on another cloud (~30 min)
    ├── ops/                         # Ongoing operations
    │   ├── backup-state.sh          # Replicate the encrypted tfstate to the -backup store
    │   ├── backup-artifacts.sh      # gpg-encrypt + upload kube/talosconfig (local-exec)
    │   ├── etcd-snapshot.sh         # Encrypted etcd snapshot → both stores (task etcd-snapshot)
    │   ├── rolling-replace.sh       # Zero-downtime node replacement (provider-agnostic targets)
    │   ├── bastion-harden-check.sh
    │   └── local-admin-portforward.sh
    ├── dev/                         # Local testing (no cloud)
    │   ├── test-talos-local.sh      # Full 3-CP + 2-worker local cluster test
    │   └── test-local-stack.sh      # Static checks (tofu fmt/validate + kustomize)
    └── internal/                    # Called by Taskfile / other scripts, not directly
        ├── resolve-s3-cred.sh
        ├── tf-backend.sh            # Derive the S3 backend config from cluster tfvars
        └── ensure-buckets.sh        # Create the per-cluster backup buckets (idempotent)
```

Kubernetes manifests live in the companion repo [dis-bzh/OpenAether-apps](https://github.com/dis-bzh/OpenAether-apps), reconciled by Flux from the management cluster.

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
quorum, Cilium, Flux, and the GitOps `ApplicationSet → Application` chain — on
the **same production `modules/talos/`** used in the cloud. Best first step.

```bash
task local-test                     # full deploy + verify (3 CP + 2 workers)
task local-status                   # etcd members + nodes + Flux
task local-flux                   # Flux UI → http://localhost:9090
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
# infra, replicates the state. PROVIDER defaults to scaleway (also ovh, outscale, proxmox).
task infra ROLE=management PROVIDER=scaleway

# Phase 2 — opens the SSH tunnels (from state), bootstraps Talos + Flux, and pushes
# the client-side-encrypted backups (kube/talosconfig + state replica).
task bootstrap-phase2 ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

### 🚧 Deploy a Workload Cluster

```bash
cp infrastructure/opentofu/cluster/envs/workload-ovh.tfvars.example \
   infrastructure/opentofu/cluster/envs/workload-ovh.tfvars   # then edit (image_id, admin_ip…)

task infra ROLE=workload PROVIDER=ovh
task bootstrap-phase2 ROLE=workload PROVIDER=ovh KEY=~/.ssh/yourkey
task register-spoke CLUSTER=openaether-ovh-prod PROVIDER=ovh   # register in the Flux hub
```

### 🚧 Cross-provider failover — second management on another cloud

```bash
# If your primary management provider is unavailable, stand one up elsewhere:
task failover PROVIDER=ovh
# RTO: ~30 minutes. Client workloads are unaffected during recovery.
```

### Static checks (no cloud, no Docker)

```bash
./scripts/dev/test-local-stack.sh        # tofu fmt/validate/test + kustomize + talosctl + yamllint
./scripts/dev/test-local-stack.sh --fast # skip talosctl gen
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
| **3** | OVH + Outscale active, Flux hub/spoke, cross-provider failover | ✅ Done |
| **4** | DNS failover (ExternalDNS + k8GB), OpenBao auto-unseal | ⏳ Planned |
| **4b** | Warm standby management on OVH (<5 min RTO) | ⏳ Planned |
| **5** | Service catalogue (Kratix / Backstage) | ⏳ Planned |
| **6** | Active-active management (Cilium ClusterMesh) | ⏳ Planned |

## License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source: **https://github.com/dis-bzh/OpenAether-infra**
