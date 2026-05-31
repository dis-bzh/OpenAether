# Provider Module Contract

Every cloud provider module in `modules/providers/<name>/` **MUST** implement
this contract to be consumed by the Talos module and the root `main.tf`.

## Required Outputs

| Output | Type | Description |
|---|---|---|
| `control_plane_private_ips` | `list(string)` | Private IPs of control plane nodes (used by Talos on 50000/TCP) |
| `worker_private_ips` | `list(string)` | Private IPs of worker nodes |
| `k8s_lb_ip` | `string` | Public IP of the Kubernetes API Load Balancer (port 6443) |
| `bastion_ip` | `string` | Public IP of the bastion host (SSH jump server) |

## Optional Outputs

| Output | Type | Description |
|---|---|---|
| `app_lb_ip` | `string` | Public IP of the application Load Balancer (ports 80/443) |
| `nat_gateway_ip` | `string` | Public IP of the NAT gateway (for LB ACL whitelisting) |

## Required Variables

| Variable | Type | Description |
|---|---|---|
| `cluster_name` | `string` | Name of the cluster (used for resource naming) |
| `control_plane_count` | `number` | Number of control plane nodes to provision |
| `worker_count` | `number` | Number of worker nodes to provision |
| `admin_ip` | `list(string)` | Allowed CIDRs for admin access (SSH, K8s API ACLs) |
| `bastion_ssh_key` | `string` | SSH public key for bastion access |

## Rules

1. **No Talos logic** — Provider modules MUST NOT contain `data.talos_machine_configuration`,
   `talos_machine_secrets`, or any Talos-specific resources. Talos configuration is handled
   exclusively by the centralized `modules/talos/` module.

2. **No `user_data` injection** — Talos machine configuration MUST NOT be injected via
   VM `user_data`. The Talos provider applies configuration via the Talos API
   (`talos_machine_configuration_apply`) after the infrastructure is provisioned.

3. **Private-first networking** — All cluster nodes (control planes + workers) SHOULD
   reside in a private network with no public IP. A bastion host provides admin access,
   and a NAT gateway provides outbound connectivity.

4. **Security groups** — Inbound default policy MUST be `drop`. Only explicitly
   required ports should be allowed (6443 from LB, 50000 from bastion, inter-node mesh).

## Architecture

```
Provider Module (cloud-specific)          Talos Module (cloud-agnostic)
┌─────────────────────────────┐          ┌──────────────────────────────┐
│ VMs (no public IP)          │          │ Machine secrets              │
│ Private Network / VPC       │──IPs──►  │ Machine configuration        │
│ Load Balancers (K8s + App)  │          │ Configuration apply (API)    │
│ Security Groups             │          │ Bootstrap (etcd)             │
│ Bastion Host                │          │ Kubeconfig retrieval         │
│ NAT Gateway                 │          │ Inline manifests (Cilium,    │
│                             │          │   ArgoCD, Root App)          │
└─────────────────────────────┘          └──────────────────────────────┘
```

## Reference Implementation

See `modules/providers/scw/` for the canonical implementation of this contract.
