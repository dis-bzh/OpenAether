# OpenAether Management Cluster (OpenTofu)

This directory contains the OpenTofu (Terraform compatible) code to deploy the OpenAether management cluster on Talos Linux across multiple providers.

## Structure

- `main.tf`: Entry point, orchestrates modules.
- `modules/`:
  - `talos/`: Generates Talos machine configuration (secrets, control plane, worker).
  - `providers/`: Provider-specific implementations.
    - `scw` (Scaleway): **[Status: Fully Deployed & Validated]** Uses `scaleway_lb` (Managed LB).
    - `ovh` (OVH): **[Status: Code Ready / Mock Tested]** Uses OpenStack Octavia.
    - `outscale` (Outscale): **[Status: Code Ready / Mock Tested]** Uses `outscale_load_balancer` (LBU).
- `tofu.tfvars.example`: Template for configuration.

## Prerequisites

- [OpenTofu](https://opentofu.org/) installed (`tofu`).
- Provider credentials exported as environment variables:
  - **Scaleway**: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID`
  - **OVH**: `OS_AUTH_URL`, `OS_TENANT_ID`, `OS_TENANT_NAME`, `OS_USERNAME`, `OS_PASSWORD`, `OS_REGION_NAME`
  - **Outscale**: `OSC_ACCESS_KEY`, `OSC_SECRET_KEY`, `OSC_REGION`

## Remote State & Security (Production)

The state is stored in an **Encrypted S3 Backend** (Scaleway Object Storage) with **Client-Side Encryption** (AES-GCM).

### 1. Export Credentials & Secrets
To initialize or apply, you **must** export the following variables:

```bash
# S3 Backend & Backup Access
export AWS_ACCESS_KEY_ID="<SCW_ACCESS_KEY>"
export AWS_SECRET_ACCESS_KEY="<SCW_SECRET_KEY>"
export AWS_DEFAULT_REGION="fr-par"

# Encryption Passphrase (Zero-Knowledge & SSE-C Key)
# Used for Client-Side State encryption AND S3 Object Backups
export TF_VAR_encryption_passphrase="<YOUR_SECURE_PASSPHRASE>"
```

### 2. Configuration Backups (SSE-C)
Critical cluster artifacts are automatically backed up to Scaleway Object Storage with **Server-Side Encryption with Customer-Provided Keys (SSE-C)**. 
- **Encryption Key**: Derived from the first 32 characters of your `encryption_passphrase`.
- **Location**: `s3-openaether-tfstate/backups/`.
- **Privacy**: Scaleway cannot access the unencrypted data without your passphrase.

### 2. Usage Sequence

1.  **Initialize**:
    ```bash
    tofu init
    ```

2.  **Configure**:
    Copy the example variables file and edit it:
    ```bash
    cp tofu.tfvars.example tofu.tfvars
    ```
    **Scaleway HA Note**: To respect quotas while maintaining HA, we use a hybrid multi-zone distribution (e.g., `["fr-par-1", "fr-par-2", "fr-par-1"]` for 3 control planes).

3.  **Plan & Apply**:
    ```bash
    tofu plan -var-file="tofu.tfvars" -out=plan
    tofu apply "plan"
    ```

## Talos Bootstrap & Connectivity

The infrastructure is private. To initialize the cluster, the `talos_machine_bootstrap` resource uses an SSH tunnel via the bastion.

### 1. Establish the Tunnel
Once the bastion is created, open a tunnel to the bootstrap node (default: `172.16.4.4`):
```bash
ssh -i <key> -L 50000:172.16.4.4:50000 ubuntu@<bastion-ip> -N &
```

### 2. Finalize Bootstrap
Run the apply again. OpenTofu will now be able to reach the Talos API on `127.0.0.1:50000` and complete the process:
```bash
tofu apply -var-file="tofu.tfvars"
```

## Security Architecture

The infrastructure uses a **zero-trust** approach:
- **No Public IPs**: Nodes are isolated in a private network.
- **Bastion Host**: Entry point with asymmetric routing protection (DHCP route overrides disabled).
- **NAT Gateway**: Outbound access for nodes.
- **Load Balancer**: Attached to the Private Network for internal/external traffic (Port 6443). ACLs restrict access to `admin_ip`.

## Post-Deployment Access

Once the bootstrap is complete, all configurations are managed in memory (no persistent local files). You can retrieve them securely using Tofu outputs:

```bash
# Retrieve Kubeconfig
tofu output -raw kubeconfig > kubeconfig
export KUBECONFIG=./kubeconfig

# Retrieve Talosconfig
tofu output -raw talosconfig > talosconfig

# Access Cluster
kubectl get nodes
```

## Troubleshooting

### Connectivity EOF/Reset via Load Balancer
If `kubectl` returns `EOF` or `connection reset`:
- Ensure the Load Balancer is attached to the Private Network.
- Check that LB ACLs allow the NAT Gateway IP (for node-to-LB traffic/hairpinning).
- Verify that Security Groups allow Scaleway internal health checks (`100.64.0.0/10`).

## Testing & DevTools

### 1. OpenTofu Tests
We use the native `tofu test` framework. Tests are located in the `tests/` directory.
```bash
task test
```

### 2. Cost Estimation (Terracost)
To estimate the cost of your infrastructure:
1. Install [Terracost](https://github.com/cycloidio/terracost).
2. Run the task:
```bash
task cost
# Then follow instructions in output
```

### 3. Infrastructure Map (Inframap)
To visualize your infrastructure:
1. Install [Inframap](https://github.com/cycloidio/inframap).
2. Run the task:
```bash
task map
# Then follow instructions in output
```
