# 🌐 OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Internal Developer Platform (IDP).

## 📋 Version

**v0.2.0** - High-Availability (HA) infrastructure provisioning with Talos Linux and OpenTofu.

## 🏗️ Architecture

OpenAether uses **Talos Linux** and a sovereign-first approach:

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu | ✅ |
| **OS** | Talos Linux (Immutable) | ✅ |
| **CNI** | Cilium | ✅ |
| **Gateway** | Traefik (Gateway API) | 🚧 Phase 2 |
| **Identity** | Keycloak + CloudNativePG | 🚧 Phase 2 |
| **Secrets** | OpenBao (Vault Fork) | 🚧 Phase 2 |
| **Mesh** | Linkerd (mTLS) | 🚧 Phase 2 |
| **Observability** | VictoriaMetrics, Loki, Grafana | 🚧 Phase 2 |

## ☁️ Provider Support

| Provider | Status | Notes |
|----------|--------|-------|
| **Scaleway** | ✅ Effective & Tested | Full HA Control Plane, whitelisted API, SSE-C Backups |
| **Outscale** | 🛠️ Code Ready | Mock tested, ready for deployment |
| **OVH** | 🛠️ Code Ready | Mock tested (OpenStack-based) |

## 📂 Repository Structure

```
OpenAether/
├── infrastructure/
│   ├── opentofu/            # OpenTofu IaC code
│   │   ├── main.tf
│   │   ├── modules/
│   │   └── tofu.tfvars.example
│   ├── legacy_pulumi/       # Old Pulumi code (archived)
├── apps/                    # Kustomize/ArgoCD (Phase 2)
│   ├── base/                # Core manifests
│   ├── overlays/            # Environment-specific
│   └── bootstrap/           # ArgoCD bootstrap
├── scripts/                 # Setup scripts
└── Taskfile.yml             # Task automation
```

## 🚀 Quick Start

### Prerequisites

- [OpenTofu](https://opentofu.org/) (`tofu`)
- `talosctl`
- `kubectl`

### Configure Environment

1. Go to the OpenTofu directory:
   ```bash
   cd infrastructure/opentofu
   ```

2. Initialize OpenTofu:
   ```bash
   tofu init
   ```

3. Create your configuration from the example:
   ```bash
   cp tofu.tfvars.example tofu.tfvars
   # Edit tofu.tfvars
   ```

### Deploy a Cluster

```bash
# Preview changes
task preview

# Deploy
task deploy
```
*Note: Ensure you have exported the necessary environment variables for your chosen providers (SCW_*, OSC_*, OS_*).*


## 🛡️ Security

- **Encrypted Remote State**: Terraform state stored in S3 with **Client-Side Encryption (AES-GCM)**.
- **Secure Artifact Backups**: `kubeconfig`, `talosconfig` and YAMLs backed up to S3 with **SSE-C (Customer-Provided Keys)**.
- **LB ACL Refactoring**: Port 6443 whitelisted to admin IPs and NAT Gateway for secure cluster management.
- **Zero-Local Policy**: No sensitive configuration files stored permanently on the local disk.
- Bastion SSH restricted to administrator IP by default.
- Talos API over mTLS.
- **OS**: Talos Linux - immutable, minimal, API-driven.
- **Network Isolation**: All nodes (Control Plane/Workers) reside in a **Private VPC** with NO public IP.
- **Admin Access**: Hardened **Bastion Host** (Jump Server) with automated asymmetric routing protection.
- **Outbound Connectivity**: **Public Gateway (NAT)** for secure image pulls and updates.
- **ACLs**: Kubernetes API whitelisted to administrator IPs on the Elastic Load Balancer (connected to private network).
- **Encryption**: Cilium with WireGuard encryption for inter-node traffic.
- **Secrets**: Never committed (`.gitignore` enforced).

## 📜 License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source code: **https://github.com/dis-bzh/OpenAether**
