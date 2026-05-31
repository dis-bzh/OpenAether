# OpenAether — OpenTofu Infrastructure

Multi-cloud Talos Kubernetes cluster provisioning. Supports Scaleway, OVH, and Outscale
with a provider-agnostic architecture via a provider contract.

## Architecture

```
tofu apply -var-file=envs/<cluster>.tfvars
  ├── Provider module (one active at a time)
  │     ├── VPC / private network
  │     ├── Control plane VMs (private IPs, multi-AZ)
  │     ├── Worker VMs (private IPs)
  │     ├── Bastion host (SSH access, public IP)
  │     ├── K8s API LB (public, 6443, ACL-restricted to admin_ip)
  │     └── App LB (public, 80/443)
  │
  ├── Talos module (cloud-agnostic)
  │     ├── Machine secrets (prevent_destroy=true)
  │     ├── Control plane config + inlineManifests:
  │     │     ├── Cilium CNI (always injected)
  │     │     ├── ArgoCD install (bootstrap only)
  │     │     └── ArgoCD root Application (bootstrap only)
  │     ├── Worker config
  │     └── Config apply → bootstrap → health check → kubeconfig
  │
  └── S3 backup (AES-GCM encrypted)
        ├── talosconfig
        ├── kubeconfig
        └── machine configs
```

### Provider Contract

Every provider module in `modules/providers/<name>/` must implement the
[provider contract](modules/providers/provider-contract.md). The root module's
junction point uses `coalesce()` to select the active provider's outputs.

**Adding a new provider = implementing the contract interface.** The Talos module
and junction point work without modification.

### Two-Phase Bootstrap

| Phase | Command | What happens |
|-------|---------|--------------|
| Phase 1 | `tofu apply -var-file=envs/<cluster>.tfvars` | VMs, networking, LBs |
| Phase 2 | `... -var talos_bootstrap=true` | Talos config, bootstrap, ArgoCD |

Between phases, establish SSH tunnels via the bastion for Talos API access (port 50000).

## Prerequisites

| Tool | Required for |
|------|-------------|
| OpenTofu >= 1.12.0 | Infrastructure provisioning |
| `talosctl` | Cluster access + validation |
| `kubectl` | App deployment |
| `helm` | Rendering bootstrap manifests |
| `jq` | DRP and register-spoke scripts |

**Credentials per provider:**

| Provider | Environment Variables |
|----------|-----------------------|
| Scaleway | `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` |
| OVH | `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_ID`, `OS_REGION_NAME` |
| Outscale | `OSC_ACCESS_KEY`, `OSC_SECRET_KEY`, `OSC_REGION` |
| All | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (S3 backup), `TF_VAR_encryption_passphrase` |

## Environment Files

One file = one cluster. State is stored separately per cluster in S3.

Only the `*.tfvars.example` templates are versioned; copy one to its real name
(`cp envs/management-scw.tfvars.example envs/management-scw.tfvars`) and fill in
`admin_ip`, `bastion_ssh_keys`, `image_name`, etc. The real `*.tfvars` are
git-ignored so credentials never get committed.

| Template | Cluster | Provider | Role |
|----------|---------|----------|------|
| `envs/management-scw.tfvars.example` | `openaether-prod` | Scaleway | management |
| `envs/workload-scw.tfvars.example` | `openaether-scw-prod` | Scaleway | workload |
| `envs/workload-ovh.tfvars.example` | `openaether-ovh-prod` | OVH | workload |
| `envs/workload-outscale.tfvars.example` | `openaether-outscale-prod` | Outscale | workload |
| `envs/drp-ovh.tfvars.example` | `openaether-prod` | OVH | management (DRP fallback) |

## Workflow

### Deploy management cluster

```bash
# Generate bootstrap manifests first (Cilium, ArgoCD)
./scripts/render-bootstrap-manifests.sh

# Phase 1
tofu apply -var-file=envs/management-scw.tfvars

# Open SSH tunnels (see: tofu output instructions)
# Then Phase 2
tofu apply -var-file=envs/management-scw.tfvars -var talos_bootstrap=true
```

### Deploy workload cluster

```bash
tofu apply -var-file=envs/workload-ovh.tfvars
# Tunnels...
tofu apply -var-file=envs/workload-ovh.tfvars -var talos_bootstrap=true
```

### DRP — Rebuild management cluster

```bash
# If Scaleway is unavailable:
./scripts/drp-management.sh ovh
# RTO: ~30 minutes. Workload clusters are unaffected.
```

### Upgrade Cilium or ArgoCD

```bash
export CILIUM_VERSION=1.20.0
export ARGOCD_VERSION=v3.4.0
./scripts/render-bootstrap-manifests.sh
tofu apply -var-file=envs/management-scw.tfvars -var talos_bootstrap=true
```

## Module Structure

```
modules/
├── talos/                 # Cloud-agnostic Talos cluster module
│   ├── main.tf            # Secrets, config, bootstrap, health check, kubeconfig
│   ├── variables.tf
│   └── outputs.tf
└── providers/
    ├── provider-contract.md   # Interface specification
    ├── scw/               # Scaleway (reference implementation)
    │   ├── main.tf        # Compute instances
    │   ├── network.tf     # VPC, IPAM, NAT gateway
    │   ├── security.tf    # Security groups
    │   ├── lb.tf          # K8s + App load balancers
    │   └── bastion.tf     # Bastion host
    ├── ovh/               # OVH / OpenStack
    │   └── (same structure as scw/)
    └── outscale/          # Outscale / Numspot
        └── (same structure as scw/)
```

## Tests

```bash
# All unit tests (26 tests, mock providers — no cloud credentials needed)
tofu test

# Individual test suites
tofu test -filter=tests/scaleway.tftest.hcl       # SCW module (9 tests)
tofu test -filter=tests/talos-config.tftest.hcl   # Talos config logic (10 tests)
tofu test -filter=tests/provider-contract.tftest.hcl  # Junction point (7 tests)

# Full local validation (tests + kustomize + talosctl + yamllint)
./scripts/test-local-stack.sh
```

## Security

| Control | Mechanism |
|---------|-----------|
| No public IPs on nodes | Private VPC only |
| Talos API | SSH tunnel via bastion (50000/TCP, never on LB) |
| Kubernetes API | LB ACL restricted to `admin_ip` |
| State encryption | AES-GCM + PBKDF2 (backend.tf) |
| Backup encryption | S3 server-side encryption |
| Inter-node | Cilium WireGuard |
| Machine secrets | `prevent_destroy = true` lifecycle guard |
