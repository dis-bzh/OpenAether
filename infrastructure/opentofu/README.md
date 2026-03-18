# OpenAether — Talos Kubernetes Cluster (OpenTofu)

Infrastructure-as-Code for deploying a production Talos Linux Kubernetes cluster on Scaleway.

## Architecture

```
tofu apply
  ├── Scaleway (infrastructure)
  │     ├── VPC + Private Network + NAT Gateway
  │     ├── Control Plane instances (private, multi-AZ)
  │     ├── Worker instances (private)
  │     ├── Bastion host (SSH access)
  │     ├── K8s API LB (permanent, 6443, ACL-restricted)
  │     └── App LB (permanent, 80/443)
  │
  ├── Talos (cluster configuration + bootstrap)
  │     ├── Machine secrets
  │     ├── Control plane config with inlineManifests:
  │     │     ├── Cilium CNI
  │     │     ├── ArgoCD installation
  │     │     └── ArgoCD root application
  │     ├── Worker config
  │     ├── Config apply → bootstrap → kubeconfig
  │     └── Local files: talosconfig, kubeconfig
  │
  └── S3 Backup (encrypted)
        └── talosconfig, kubeconfig, machine configs
```

### Network Access Strategy

| Port | Service | Access Method |
|------|---------|---------------|
| 6443/TCP | Kubernetes API | K8s LB (permanent, ACL-restricted) |
| 50000/TCP | Talos API | Bastion SSH tunnel only (**never** via LB) |
| 80/443 | Applications | App LB (permanent) |
| 22/TCP | SSH | Bastion only (admin_ip restricted) |

### Bootstrap Flow (Day 0)

1. **`tofu apply`** provisions all infrastructure
2. Talos machine configs include `inlineManifests` for Cilium, ArgoCD, root app
3. Control planes bootstrap with CNI + GitOps ready
4. ArgoCD root app syncs `apps/overlays/prod/` → manages all workloads

### Day 1 / Day 2

- **Day 1**: `tofu apply` is a no-op (idempotent)
- **Day 2**: Update manifests or config → `tofu apply` applies changes

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.11.0
- Scaleway credentials: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID`
- S3 backend: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- Encryption: `TF_VAR_encryption_passphrase` (32+ chars)
- Bootstrap manifests generated (see below)

## Quick Start

### 1. Generate Bootstrap Manifests

```bash
# Requires: helm, curl
./scripts/render-bootstrap-manifests.sh
```

This renders Cilium and ArgoCD install manifests into `bootstrap-manifests/`.

### 2. Configure

```bash
cp tofu.tfvars.example tofu.tfvars
# Edit tofu.tfvars with your values
```

### 3. Deploy

```bash
# Establish SSH tunnel to bastion for Talos API access
# (get bastion IP from a previous apply or Scaleway console)
ssh -i ~/.ssh/key -L 50000:<cp0-private-ip>:50000 ubuntu@<bastion-ip> -N &

# Deploy
tofu init
tofu apply -var-file=tofu.tfvars
```

### 4. Access

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes

export TALOSCONFIG=./talosconfig
talosctl --endpoints 127.0.0.1 health
```

## Structure

```
├── main.tf                 # Root orchestration
├── variables.tf            # Input variables
├── versions.tf             # Provider versions
├── outputs.tf              # Operational outputs
├── backup.tf               # S3 encrypted backup
├── backend.tf              # Remote state config
├── bootstrap-manifests/    # Static manifests for Talos inlineManifests
│   ├── cilium.yaml         # Generated via helm template
│   ├── argocd-install.yaml # Official ArgoCD install manifest
│   └── argocd-root-app.yaml.tftpl  # Root app template
├── modules/
│   ├── talos/              # Talos secrets, config, bootstrap, kubeconfig
│   └── providers/
│       └── scw/            # Scaleway infrastructure
└── tests/                  # OpenTofu test framework
```

## Security

- **No public IPs** on cluster nodes
- **Bastion host** as single SSH entry point
- **50000/TCP never exposed** on any load balancer
- **K8s API LB** restricted by ACL to `admin_ip`
- **State encryption** via AES-GCM with PBKDF2 key derivation
- **Backup encryption** via S3 SSE (AES-256)

## Upgrading Bootstrap Components

```bash
# Update versions
export CILIUM_VERSION=1.17.0
export ARGOCD_VERSION=v2.14.0

# Re-render manifests
./scripts/render-bootstrap-manifests.sh

# Apply (Talos will update inlineManifests)
tofu apply -var-file=tofu.tfvars
```
