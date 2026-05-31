# OpenAether — Local 3-CP Talos Test (Docker)

Exercises the **production `modules/talos/`** end-to-end on a real **3 control plane**
Talos cluster running in Docker — no cloud credentials. Use it to validate config
generation, etcd quorum, bootstrap, kubeconfig retrieval, Cilium, and the ArgoCD
GitOps chain before spending money in the cloud.

> No S3 backend (local state). Reuses the shared `../opentofu/modules/talos/` and
> `../opentofu/modules/providers/local/`.

## What it validates (production `modules/talos/`)

| Resource | Local | Notes |
|---|---|---|
| `talos_machine_secrets` | ✅ | PKI |
| `data.talos_client_configuration` | ✅ | talosconfig |
| `data.talos_machine_configuration` | ✅ | **the real config** (certSANs, CNI=none, proxy off, kubePrism, inlineManifests, hostDNS) |
| `talos_machine_bootstrap` | ✅ | 3-node etcd quorum |
| `talos_cluster_kubeconfig` | ✅ | kubeconfig (rewritten to 127.0.0.1) |
| `data.talos_cluster_health` | ☁️ cloud-only | stalls behind WSL2 port mappings; verified here via `talosctl health` (skip_health_check=true) |
| `talos_machine_configuration_apply` | ☁️ cloud-only | Docker uses USERDATA delivery (Talos platform docs); maintenance-apply reboot-loops in containers |

Plus, on top of the cluster: Cilium CNI on all 3 nodes, ArgoCD, and the
`ApplicationSet → Application` hub mechanism.

## Quick start

```bash
# One command — full 3-CP deploy + verify (etcd quorum, Cilium, ArgoCD, GitOps)
TF_VAR_encryption_passphrase="local-test-passphrase-32chars-minimum" \
  ./scripts/test-talos-local.sh

# Or via task:
task local-render-manifests   # render simplified Cilium (no WireGuard)
task local-up                 # deploy the 3-CP cluster
task local-status             # etcd members + nodes + ArgoCD
task local-argocd             # ArgoCD UI → https://localhost:8080
task local-down               # tear down
```

## How config reaches nodes (cloud vs local)

`modules/talos` supports two delivery modes via `config_delivery`:

| | Cloud (`apply`) | Local Docker (`userdata`) |
|---|---|---|
| Mechanism | `talos_machine_configuration_apply` (gRPC maintenance apply) | config injected at container start via `USERDATA` env |
| Why | VMs boot from a disk image in maintenance mode | maintenance-apply reboot-loops in containers (Talos Docker docs) |
| Config content | identical (same `data.talos_machine_configuration`) | identical |

The generated config is the **same** — local proves it boots a real 3-CP cluster.

## Networking (WSL2 + Docker Desktop)

```
WSL2 host (OpenTofu + talosctl + kubectl)
  │  container IPs (10.5.0.x) are NOT routable from the host →
  │  reach the APIs via 127.0.0.1 port mappings:
  ├─ 127.0.0.1:50000 → cp-0:50000   (Talos API)   node identity 10.5.0.10
  ├─ 127.0.0.1:50001 → cp-1:50000   (Talos API)   node identity 10.5.0.11
  ├─ 127.0.0.1:50002 → cp-2:50000   (Talos API)   node identity 10.5.0.12
  └─ 127.0.0.1:6443  → cp-0:6443    (K8s API)

Containers (ghcr.io/siderolabs/talos): --read-only, PLATFORM=container,
  tmpfs /run /system /tmp + volumes /system/state /var /etc/cni /etc/kubernetes
  /usr/libexec/kubernetes /opt ; static IPs on a 10.5.0.0/24 Docker network.
Inter-node (etcd, kube) uses the 10.5.0.x network directly.
```

`modules/talos` is fed `control_plane_ips` (10.5.0.x, node identity) and
`control_plane_endpoints` (127.0.0.1:5000x, host-reachable) — the split keeps the
cloud path unchanged (endpoints default to the node IPs there).

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `control_plane_count` | `3` | 3 for a real quorum, 1 for a quick smoke test |
| `talos_bootstrap` | `false` | `true` builds the full cluster |
| `cilium_manifest` | `null` | set via `TF_VAR_cilium_manifest` from `cilium-local.yaml` |

## Troubleshooting

```bash
# etcd quorum
talosctl --nodes 10.5.0.10 --endpoints 127.0.0.1:50000 etcd members

# a container reboot-loops → check the boot phase
docker logs openaether-local-dev-cp-0 2>&1 | grep -E "phase|boot sequence|failed"

# Docker Desktop port-forward errors ("/forwards/expose 500") after many cycles
#   → restart Docker Desktop; the daemon degrades after heavy create/destroy churn

# full reset
task local-down
```
