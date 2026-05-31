# OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Cloud Management Platform (CMP).

## Version

**v0.3.0** — Multi-cloud infrastructure with hub/spoke GitOps and DRP automation.

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

**Design principle:** The management cluster is NOT in the client data path. If the management cluster is temporarily unavailable, client workloads continue running unaffected. Management plane RTO: ~30 min (DRP) → Phase 4 target: <5 min.

## Layer Status

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.12.6 (Immutable) | ✅ |
| **CNI** | Cilium 1.19.2 (WireGuard) | ✅ |
| **GitOps** | ArgoCD v3.3.2 (hub/spoke) | ✅ |
| **Gateway** | Traefik v3.0 (Gateway API) | 🚧 Phase 2 |
| **Identity** | Keycloak 26.0 + CloudNativePG | 🚧 Phase 2 |
| **Secrets** | OpenBao 2.2.0 (Vault fork) | 🚧 Phase 2 |
| **Observability** | VictoriaMetrics v1.102.0, Grafana 11.2.0 | 🚧 Phase 2 |
| **Autoscaling** | KEDA v2.15.1 | 🚧 Phase 2 |
| **Policy** | Kyverno v1.12.0 | 🚧 Phase 2 |

## Cloud Provider Support

| Provider | Status | Region | Notes |
|----------|--------|--------|-------|
| **Scaleway** | ✅ Operational | fr-par (3 AZs) | HA control plane, full networking stack |
| **OVH** | ✅ Code complete | GRA (OpenStack) | Octavia LB, floating IPs, private network |
| **Outscale / Numspot** | ✅ Code complete | eu-west-2 | Load balancer, NAT, VPC |

## Repository Structure

```
OpenAether/
├── infrastructure/
│   └── opentofu/                    # Infrastructure as Code
│       ├── main.tf                  # Provider orchestration + junction point
│       ├── variables.tf             # node_distribution, cluster_role, etc.
│       ├── envs/                    # Per-cluster tfvars files
│       │   ├── management-scw.tfvars
│       │   ├── workload-scw.tfvars
│       │   ├── workload-ovh.tfvars
│       │   ├── workload-outscale.tfvars
│       │   └── drp-ovh.tfvars       # DRP management cluster
│       ├── modules/
│       │   ├── talos/               # Cluster secrets, config, bootstrap
│       │   └── providers/
│       │       ├── scw/             # Scaleway (reference implementation)
│       │       ├── ovh/             # OVH / OpenStack
│       │       ├── outscale/        # Outscale / Numspot
│       │       └── provider-contract.md
│       └── tests/                   # OpenTofu unit tests (26 tests total)
│           ├── scaleway.tftest.hcl
│           ├── talos-config.tftest.hcl
│           └── provider-contract.tftest.hcl
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
    ├── drp-management.sh            # Rebuild management cluster (~30 min)
    └── test-local-stack.sh          # Full local validation (no cloud needed)
```

## Quick Start

### Prerequisites

```bash
# Install all tools
./scripts/setup.sh

# Required tools: tofu, talosctl, kubectl, task, helm, yamllint
```

### Deploy the Management Cluster (Scaleway)

```bash
cd infrastructure/opentofu

# 1. Initialize
tofu init

# 2. Configure your environment (copy the template, then edit)
cp envs/management-scw.tfvars.example envs/management-scw.tfvars
# Edit: admin_ip, bastion_ssh_keys, backup_s3_bucket, etc.
# The real envs/*.tfvars are git-ignored; only the *.tfvars.example are versioned.

# 3. Phase 1 — Provision infrastructure
task deploy-management
# or: tofu apply -var-file=envs/management-scw.tfvars

# 4. Establish SSH tunnels via bastion (one per control plane)
# See: tofu output instructions

# 5. Phase 2 — Bootstrap Talos + ArgoCD
task bootstrap-management
# or: tofu apply -var-file=envs/management-scw.tfvars -var talos_bootstrap=true
```

### Deploy a Workload Cluster

```bash
# OVH example — set OS_* env vars first
export OS_AUTH_URL=https://auth.cloud.ovh.net/v3
export OS_USERNAME=...

# cp envs/workload-ovh.tfvars.example envs/workload-ovh.tfvars
# Edit envs/workload-ovh.tfvars with your image_id and credentials

task deploy-workload PROVIDER=ovh
# After SSH tunnels:
task bootstrap-workload PROVIDER=ovh

# Register the new cluster in ArgoCD hub
task register-spoke CLUSTER=openaether-ovh-prod PROVIDER=ovh
```

### DRP — Management Cluster Recovery

```bash
# If Scaleway is unavailable, rebuild management cluster on OVH
task drp PROVIDER=ovh
# RTO: ~30 minutes. Client workloads are unaffected during recovery.
```

### Local Validation (No Cloud Needed)

```bash
# Runs all checks: tofu fmt/validate/test, kustomize build, talosctl validate, yamllint
./scripts/test-local-stack.sh

# Fast mode (skip talosctl gen)
./scripts/test-local-stack.sh --fast
```

## Security

| Control | Implementation |
|---------|----------------|
| No public IPs on cluster nodes | VPC-only, bastion SSH tunnel |
| State encryption | AES-GCM + PBKDF2 in S3 |
| Artifact backup encryption | S3 SSE-C |
| Kubernetes API access | LB ACL restricted to `admin_ip` |
| Talos API access | SSH tunnel only (port 50000, never on LB) |
| Inter-node encryption | Cilium WireGuard |
| Secrets management | OpenBao (Vault fork, open source) |

## Roadmap

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **3** | OVH + Outscale active, ArgoCD hub/spoke, DRP automated | ✅ Done |
| **4** | DNS failover (ExternalDNS + k8GB), OpenBao auto-unseal | ⏳ Planned |
| **4b** | Warm standby management on OVH (<5 min RTO) | ⏳ Planned |
| **5** | Service catalogue (Kratix / Backstage) | ⏳ Planned |
| **6** | Active-active management (Cilium ClusterMesh) | ⏳ Planned |

## License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source: **https://github.com/dis-bzh/OpenAether**
