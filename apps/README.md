# Applications & Workloads (`apps/`)

This directory contains all Kubernetes manifests managed by GitOps (ArgoCD).

## Directory Structure

### `base/` (The "What")
**Purpose**: Contains the **agnostic** definitions of services and applications.
- **Rule**: These files should be runnable in ANY environment (Local, Dev, Prod, Azure, AWS, On-Prem).
- **Content**: Deployment definitions, Services, default RBAC.
- **HA & Spreading**: By default, components here include `topologySpreadConstraints` for high availability across zones/nodes.

### `overlays/` (The "Context")
**Purpose**: Modifications specific to an environment.
- **`local/`**: Patches for the local environment (e.g., specific Hostnames, Replicas=1, simplified security).
- **`prod/`**: Patches for production (High Availability, Specific Ingress Domains, Cloud Specific Annotations).

### `bootstrap/` (The "Ignition")
**Purpose**: ArgoCD installation and root application configuration.
- **Installation**: Managed by Terraform (`infrastructure/opentofu/helm.tf`)
- **Root App**: Automatically deployed by Terraform (`infrastructure/opentofu/argocd-root-app.tf`)
- **Overlays**: 
  - `local/` - For local development (insecure mode, single replicas)
  - `prod/` - For production (TLS enabled, HA configuration)

## Multi-Cloud & High Availability
All key services in `base/` are configured with `topologySpreadConstraints` to ensure:
1. **Zone Redundancy**: Pods are spread across availability zones (`topology.kubernetes.io/zone`).
2. **Node Distribution**: Pods are spread across different nodes (`kubernetes.io/hostname`).

### Local Simulation
On local clusters (likely single node or virtual multi-node), these constraints might prevent scheduling if not handled.
- **Solution**: The `local` overlay may patch these constraints out OR we verify the local cluster nodes have appropriate fake labels.

## Flow
1. **Bootstrap**: `task bootstrap` -> Installs ArgoCD.
2. **Sync**: ArgoCD wakes up -> Reads `apps/bootstrap/overlays/local/root-app.yaml` -> Points to `apps/overlays/local`.
3. **Deploy**: ArgoCD applies `apps/overlays/local` -> Which pulls `apps/base/*` + applied patches.
