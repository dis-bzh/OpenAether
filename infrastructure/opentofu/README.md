# OpenAether Management Cluster (OpenTofu)

This directory contains the OpenTofu (Terraform compatible) code to deploy the OpenAether management cluster on Talos Linux across multiple providers.

## Structure

- `main.tf`: Entry point, orchestrates modules.
- `modules/`:
  - `talos/`: Generates Talos machine configuration (secrets, control plane, worker).
  - `providers/`: Provider-specific implementations.
    - `scw` (Scaleway): Uses `scaleway_lb` (Managed LB).
    - `ovh` (OVH): Uses OpenStack Octavia (`openstack_lb_loadbalancer_v2`) and Floating IP.
    - `outscale` (Outscale): Uses `outscale_load_balancer` (LBU).
- `tofu.tfvars.example`: Template for configuration.

## Prerequisites

- [OpenTofu](https://opentofu.org/) installed (`tofu`).
- Provider credentials exported as environment variables:
  - **Scaleway**: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID`
  - **OVH**: `OS_AUTH_URL`, `OS_TENANT_ID`, `OS_TENANT_NAME`, `OS_USERNAME`, `OS_PASSWORD`, `OS_REGION_NAME`
  - **Outscale**: `OSC_ACCESS_KEY`, `OSC_SECRET_KEY`, `OSC_REGION`

## Usage

1. **Initialize**:
   ```bash
   tofu init
   ```

2. **Configure**:
   Copy the example variables file and edit it:
   ```bash
   cp tofu.tfvars.example tofu.tfvars
   ```
   **Important**: Check specific variables needed for providers (e.g., `image_id` for Talos snapshots).

3. **Plan**:
   ```bash
   tofu plan -var-file="tofu.tfvars"
   ```

4. **Apply**:
   ```bash
   tofu apply -var-file="tofu.tfvars"
   ```

## Security Architecture

The infrastructure is designed with a **zero-trust** approach:
- **No Public IPs**: Cluster nodes (Control Plane & Workers) are isolated in a private network.
- **Bastion Host**: A hardened entry point for all administrative tasks.
- **NAT Gateway**: Provides secure outbound internet access for image pulls and Talos discovery.
- **ACLs**: The Kubernetes API (Load Balancer) is whitelisted for authorized admin IPs only.

## Post-Deployment Access

### 1. Opening Management Tunnels

To manage the cluster from your local machine, establish SSH tunnels via the bastion:

```bash
# Talos API (Management)
ssh -i <key> -L 50000:<target-node-private-ip>:50000 ubuntu@<bastion-ip> -N &

# Kubernetes API
ssh -i <key> -L 6443:<cp-private-ip>:6443 ubuntu@<bastion-ip> -N &
```

### 2. Standard Tools usage

Once tunnels are active, point your tools to `localhost`:

```bash
export TALOSCONFIG=./talosconfig
export KUBECONFIG=./kubeconfig

talosctl health --nodes localhost --endpoints localhost
kubectl get nodes
```

## Troubleshooting

### Unused Providers Initialization Error

OpenTofu initializes all providers defined in the configuration, even if they are not used in your current `node_distribution`. If you are only deploying to one provider (e.g., Scaleway), you may still see errors asking for credentials for others (OVH, Outscale).

To bypass this without finding real credentials, export dummy values for the unused providers:

```bash
# Example: If only using Scaleway, export these dummy values for OVH and Outscale
export OS_AUTH_URL="http://localhost"
export OS_REGION_NAME="RegionOne"
export OSC_REGION="us-east-1"
export OSC_ACCESS_KEY="dummy"
export OSC_SECRET_KEY="dummy"
```
