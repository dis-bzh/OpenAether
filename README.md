# 🌐 OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Internal Developer Platform (IDP).

## 🏗️ Architecture

OpenAether uses **Talos Linux** and a sovereign-first approach:

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | Pulumi (Go) | ✅ |
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
| **Docker** | ✅ Production | Local Talos-in-Docker for dev/test |
| **Outscale** | ✅ Production | 3DS sovereign cloud (EU) |
| **Scaleway** | ✅ Production | EU sovereign cloud |
| **OVH** | 🚧 Planned | OpenStack-based |

## 📂 Repository Structure

```
OpenAether/
├── infrastructure/          # Pulumi Go code
│   ├── main.go              # Entry point
│   ├── pkg/cluster/         # Provider implementations
│   ├── pkg/components/      # Cilium, etc.
│   ├── environments/        # .env.local, .env.test, etc.
│   └── sdks/                # Outscale SDK
├── apps/                    # Kustomize/ArgoCD (Phase 2)
│   ├── base/                # Core manifests
│   ├── overlays/            # Environment-specific
│   └── bootstrap/           # ArgoCD bootstrap
├── scripts/                 # Setup scripts
└── Taskfile.yml             # Task automation
```

## 🚀 Quick Start

### Prerequisites

```bash
# Install dependencies
task setup

# For Docker provider (local dev)
sudo modprobe br_netfilter
```

### Configure Environment

```bash
# Copy example config
cp infrastructure/.env.example infrastructure/environments/.env.prod
```

### Deploy a Cluster

```bash
# Local Docker cluster
task deploy ENV=local

# Test in cloud
task deploy ENV=test

# Prod in cloud
task deploy ENV=prod

# Preview changes without applying
task preview ENV=test
```

### Access the Cluster

```bash
# Check cluster status
task status ENV=test

# Export kubeconfig separately
task kubeconfig ENV=test

# Use kubectl directly
kubectl --kubeconfig kubeconfig-test.yaml get nodes
```

### Destroy a Cluster

```bash
task destroy ENV=test
```

## ⚙️ Multi-Provider Mode

Deploy nodes across multiple providers using `NODE_DISTRIBUTION`:

```bash
# .env example
NODE_DISTRIBUTION=outscale:3:2
# Format: provider:controlplanes:workers
```

This deploys 3 control-plane + 2 worker on Outscale.

## 🛠️ Available Tasks

```bash
task              # Show all available tasks
task setup        # Run initial setup
task lint         # Run linters (golangci-lint, yamllint)
task test         # Run Go tests
task deploy       # Deploy cluster (ENV=local|test|prod)
task destroy      # Destroy cluster
task preview      # Preview changes
task status       # Show cluster status
task kubeconfig   # Export kubeconfig
```

## 🛡️ Security

- **OS**: Talos Linux - immutable, minimal, API-driven
- **CNI**: Cilium with WireGuard encryption
- **Secrets**: Never committed (`.gitignore` enforced)

## 🔧 Troubleshooting

### `Failed to check br_netfilter` (Docker)
```bash
sudo modprobe br_netfilter
task destroy ENV=local && task deploy ENV=local
```

### Pulumi state issues
```bash
pulumi login --local
pulumi stack select <env> --create
```

## 📜 License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source code: **https://github.com/dis-bzh/OpenAether**

### Third-Party Components

| Component | License |
|-----------|---------|
| Pulumi | Apache 2.0 |
| Talos Linux | MPL 2.0 |
| Cilium | Apache 2.0 |
| Outscale SDK | Apache 2.0 |
