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
- `task` (Taskfile)

### Configure Environment

1. **Install Dependencies**:
   Run the included setup script to install all required tools (OpenTofu, Talosctl, Kubectl, Task, etc.):
   ```bash
   chmod +x scripts/setup.sh
   ./scripts/setup.sh
   ```

2. Go to the OpenTofu directory:
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

### ☁️ Provider Selection

OpenAether supports **one active cloud provider at a time**. This is enforced by the configuration in `tofu.tfvars`.
To select a provider (e.g., Scaleway), set its node count to > 0 and ensure others are 0 in the `node_distribution` variable:

```hcl
node_distribution = {
  scaleway = { control_planes = 3, workers = 1, ... } # ACTIVE
  ovh      = { control_planes = 0, workers = 0, ... } # DISABLED
  outscale = { control_planes = 0, workers = 0, ... } # DISABLED
}
```

### 🗄️ Remote Backend (Output S3)

By default, OpenTofu uses a **local state** (`terraform.tfstate`). For production (or team usage), you should configure an S3-compatible backend.

1. Create a file `backend.tf`:
   ```hcl
   terraform {
     backend "s3" {
       bucket                      = "s3-openaether-tfstate"
       key                         = "terraform.tfstate"
       region                      = "fr-par"
       endpoint                    = "https://s3.fr-par.scw.cloud"
       skip_credentials_validation = true
       skip_region_validation      = true
     }
   }
   ```

2. Initialize with backend config:
   ```bash
   tofu init
   ```
   *Note: Ensure you satisfy the backend authentication (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY) env vars.*

### Deploy a Cluster

```bash
# Preview changes
task preview

# Deploy
task deploy
```
*Note: Ensure you have exported the necessary environment variables for your chosen providers (SCW_*, OSC_*, OS_*).*

### 🔐 Cluster Access & Bootstrap

Since the Kubernetes API relies on a private Load Balancer and the Talos API on private nodes, you must access them via the Bastion host.

1. **Establish SSH Tunnel**:
   ```bash
   # In a separate terminal
   ssh -i <path_to_key> -L 6443:<lb_ip>:6443 -L 50000:<control_plane_ip>:50000 ubuntu@<bastion_ip>
   ```

2. **Configure Access**:
   - **Talos**: `talosctl config endpoint 127.0.0.1`
   - **Kubernetes**: Ensure `kubeconfig` points to `https://127.0.0.1:6443`

3. **Bootstrap Applications (ArgoCD)**:
   ```bash
   task bootstrap
   ```

### 🔮 Future Roadmap

- **Service Mesh**: Evaluation of **Cilium Service Mesh** to replace Linkerd (simplifying the stack).
- **Database**: Migration from CockroachDB to **CloudNativePG** (Completed).
- **Secrets**: **OpenBao** High Availability with Raft storage (Completed).


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
