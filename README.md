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
| **Scaleway** | ✅ HA Production | Multi-zone Control Plane support |
| **Outscale** | ✅ Production | 3DS sovereign cloud (EU) |
| **OVH** | ✅ Production | OpenStack-based |
| **Docker** | ⚠️ Legacy | Moved to legacy, use Talos-in-Docker manually if needed |

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
