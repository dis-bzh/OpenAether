# OpenAether-infra — Deployment Test Matrix

> Exhaustive, deduplicated list of the deployment cases this stack can produce, and
> which have actually been exercised. Derived from the code (`cluster/variables.tf`,
> `cluster/main.tf`, the five provider modules, `modules/talos/variables.tf`,
> `provider-contract.md`, `Taskfile.yml`, and the `envs/*.tfvars.example`).
>
> Status legend: ✅ apply-tested · 🧪 unit-tested only (`tofu test`, mocked) · ⬜ untested
>
> Last reviewed: 2026-07-15.

## Mental model

One **env file = one cluster = one provider**. `cluster/main.tf` enforces a single
active provider per apply (`check "single_provider_per_cluster"`); the active provider
is whichever `node_distribution.<provider>` key has `control_planes + workers > 0`. The
provider module renders infra (LB / network / bastion); the **provider-agnostic**
`modules/talos` then renders identical Talos config regardless of provider. Local Docker
is a **separate root** (`infrastructure/opentofu-local`), not selectable via
`node_distribution`.

Two orthogonal layers of knobs:

- **Infra-shaping** (per provider): provider, zones/hosts, `k8s_lb_mode`, bastion, worker disks.
- **Talos / operational** (provider-agnostic): `cluster_role`, `talos_bootstrap` phase, VIP
  injection, `secrets_prevent_destroy`, `auto_tunnels`, `backup_enabled`, test-only skips.

## A) Dimensions

| Dimension | Variable path | Valid values | Default | Applicability | Notes |
|---|---|---|---|---|---|
| Provider | `node_distribution.<key>` (scaleway/ovh/outscale/proxmox); `local` = separate `opentofu-local` root | one active | `{}` | — | Exactly one active per apply. |
| Cluster role | `cluster_role` | `management`, `workload` | `workload` | all | Only drives the Flux bootstrap manifest. "management" later gets CAPI + deps via `OpenAether-apps` (no CAPI knob in tofu). `failover-*` = management role on a non-primary provider. |
| Environment | `environment` | `dev`, `prod` | required | all | Naming / bucket suffix only — not a topology axis. |
| CP topology (HA) | `node_distribution.<p>.control_planes`; local `control_plane_count` | 1 = non-HA, 3 = HA (local validated `{1,3}`) | 0 / local 3 | all | etcd quorum needs odd ≥3. Non-HA CP tainted `NoSchedule`. |
| Worker count | `node_distribution.<p>.workers`; local `worker_count` | ≥0 (local `0..3`) | 0 / local 3 | all | 0 workers → workloads on (untainted) CPs. |
| k8s LB mode | `node_distribution.<p>.k8s_lb_mode` | `managed`, `vip` | `managed` | **scw, ovh** only; outscale = managed-only (rejects vip); proxmox = always VIP; local = neither | `vip` (EXPERIMENTAL): no LB, private IPAM addr + Talos Layer2 VIP → **API private-only via bastion tunnel**. |
| apiserver VIP | `local.apiserver_vip` → `module.talos.apiserver_vip`; proxmox `node_distribution.proxmox.apiserver_vip` (required) + `apiserver_vip_interface` | IP / null | null (cloud); required (proxmox) | proxmox always; scw/ovh only in vip mode | Injected as `machine.network.interfaces[].vip` + certSANs. Ignored in container mode. |
| App LB | (no toggle) contract `app_lb_ip` | provider-inherent | on | scw/ovh/outscale create app LB (80/443); proxmox = host DNAT; local = `127.0.0.1` | Not a test knob. |
| Zones / AZ | scw `.zone`+`.zones`; ovh/outscale `.availability_zones`; proxmox `.node_names` (round-robin) | e.g. scw `["fr-par-1","fr-par-2","fr-par-3"]`; proxmox `["pve1"]` / `["pve1","pve2","pve3"]` | per example | cloud + proxmox | Single vs multi-AZ HA. Proxmox: 1 host = non-HA, 3 hosts = **true** HA; 3 CP on 1 host = fake HA (avoid). |
| Bastion | proxmox `node_distribution.proxmox.enable_bastion` | `true` (VM) / `false` (host-as-bastion) | `false` | proxmox toggle; scw/ovh/outscale always a dedicated VM; local none | Contract requires `bastion_ip`. |
| Worker storage | `worker_storage.disks[]` + `worker_storage.volumes[]` (LUKS2 `UserVolumeConfig`) | none, or disks+volumes | `{disks=[],volumes=[]}` | scw/ovh/outscale/proxmox; local forced off | `disks` → provider module; `volumes` → `modules/talos`. |
| Bootstrap phase | `talos_bootstrap` | `false` (Phase 1 infra), `true` (Phase 2 config+etcd+Flux) | `true` | all | `task infra` → `task bootstrap-phase2`. |
| auto_tunnels | `auto_tunnels` (+ `ssh_key_path`) | `true`/`false` | `false` | cloud/proxmox | EXPERIMENTAL single-apply; untested on a real host. |
| secrets_prevent_destroy | `secrets_prevent_destroy` | `true`/`false` | `true` | all | `false` only for `tofu test` cleanup. |
| skip_port_ready_wait | `skip_port_ready_wait` | `true`/`false` | `false` | all | `true` only for mocked CI. |
| backup_enabled | `backup_enabled` | `true`/`false` | `true` | root | `false` skips backup local-exec. |
| Talos / K8s version | `talos_version`, `kubernetes_version` | version strings | per example | all | Drives image name lookup. |
| admin_ip | `admin_ip` (list) | CIDRs | required | all | LB ACL / SG / host nftables allow-list. |

## B) Meaningful test cases

### Excluded / invalid / redundant — do **not** test

| Combo | Why |
|---|---|
| ≥2 providers with count>0 in one apply | Blocked by `check "single_provider_per_cluster"`. |
| `outscale` + `k8s_lb_mode="vip"` | Provider validation rejects it (DNS-name LB). |
| `proxmox` + any `k8s_lb_mode` | Ignored — proxmox always uses the Talos VIP (`apiserver_vip` required). |
| `local-docker` + LB / storage / bootstrap-manifest Flux | No LB (cp0 IP); volumes forced off; Flux installed post-boot. |
| `apiserver_vip` with cloud `k8s_lb_mode="managed"` | Resolves to null. |
| 3 CP on a single Proxmox host | Fake HA — real HA = multi-host. |
| local CP ∉ {1,3} or workers >3 | Validation error. |
| `dev` vs `prod` as a topology | Naming only — fold into any case. |

### local-docker (`opentofu-local` root)

| ID | CP/W | Uniquely exercises | Status |
|---|---|---|---|
| `L-ha` | 3+3 | Real 3-node etcd quorum, dedicated schedulable workers, Cilium, Flux/GitOps, `userdata` delivery — primary creds-free proof of `modules/talos`. | ✅ (`task local-test`) |
| `L-smoke` | 1+0 | Fast single-node smoke; untainted-CP scheduling fallback. | ⬜ |

### Scaleway (reference provider — full axis sweep)

| ID | Role | CP/W | k8s_lb_mode | Zones | Storage | Uniquely exercises | Status |
|---|---|---|---|---|---|---|---|
| `SCW-mgmt-nonha` | mgmt | 1+1 | managed | single | none | Cheapest cloud path; non-HA CP taint; managed LB ACL. | ✅ |
| `SCW-mgmt-ha` | mgmt | 3+2 | managed | 3-AZ | none | etcd across 3 zones; multi-AZ distribution; mgmt Flux. | ⬜ |
| `SCW-vip` | mgmt | 3+1 | **vip** | multi-AZ | none | Drops LB; `scaleway_ipam_ip.k8s_vip`; Talos Layer2 VIP; private API via tunnel; anti-spoofing behaviour. | ✅ *(3 CP fr-par-1+2, 2026-07-15)* |
| `SCW-work-ha` | workload | 3+3 | managed | 3-AZ | none | Workload Flux bootstrap path. | ⬜ |
| `SCW-storage` | workload | 3+3 | managed | 3-AZ | **disks+volumes** | SBS block volumes + encrypted `UserVolumeConfig` (LUKS2). | ⬜ |

### OVH (OpenStack)

| ID | Role | CP/W | k8s_lb_mode | Uniquely exercises | Status |
|---|---|---|---|---|---|
| `OVH-mgmt-ha` | mgmt | 3+2 | managed | Octavia LB + floating IP; OpenStack ports; Ubuntu bastion. | ⬜ |
| `OVH-vip` | mgmt | 3+2 | **vip** | `allowed_address_pairs` on CP ports for Neutron anti-spoof (distinct mechanism from Scaleway). | 🧪 |
| `OVH-work-ha` | workload | 3+3 | managed | Workload role on OVH. | ⬜ |
| `OVH-storage` | workload | 3+3 | managed | Cinder volume attach + volumes. | ⬜ |

### Outscale (managed-only, DNS-name LB)

| ID | Role | CP/W | k8s_lb_mode | Uniquely exercises | Status |
|---|---|---|---|---|---|
| `OSC-mgmt-ha` | mgmt | 3+2 | managed | LB returns **DNS name** not IP; outscale SSH user. | ⬜ |
| `OSC-work-ha` | workload | 3+3 | managed | Workload role; BSU volumes if paired with storage. | ⬜ |
| `OSC-vip-reject` | — | any | vip | Negative test: validation must reject `vip`. | 🧪 |

### Proxmox (bare-metal, always-VIP, host-as-bastion)

| ID | Role | CP/W | node_names | Bastion | Uniquely exercises | Status |
|---|---|---|---|---|---|---|
| `PMX-nonha-host` | mgmt | 1+1 | `["pve1"]` | host | Single-host non-HA; Talos VIP; static `cidrhost()` IPs; no LB/NAT/SG. | ⬜ |
| `PMX-work-nonha` | workload | 1+1 | `["pve1"]` | host | Workload role on-prem. | ⬜ |
| `PMX-ha-multihost` | mgmt | 3+n | `["pve1","pve2","pve3"]` | host | True on-prem HA: 1 CP/host, VIP floats across hosts; L2 bridge. | ⬜ |
| `PMX-vm-bastion` | mgmt | 1+1 | `["pve1"]` | **VM** (`enable_bastion=true`) | Dedicated bastion VM path + `bastion_ssh_keys.proxmox`. | ⬜ |
| `PMX-storage` | workload | 1+1 | `["pve1"]` | host | Extra Proxmox data disk + encrypted volume. | ⬜ |

### Cross-cutting operational scenarios (any provider, run once)

| ID | Key vars | Uniquely exercises | Status |
|---|---|---|---|
| `OP-twophase` | `talos_bootstrap=false` then `true` | Documented `task infra` → `task bootstrap-phase2` split. | ✅ (via `task up`) |
| `OP-autotunnels` | `auto_tunnels=true` + `ssh_key_path` | EXPERIMENTAL single-apply; untested on a real host. | ⬜ |
| `OP-failover` | `failover-<p>.tfvars`, `task failover` | Cross-provider 2nd management cluster; re-register spokes. | ⬜ |
| `OP-destroy` | `task destroy` | `prevent_destroy` PKI untrack + count=0 destroy path. | ✅ |
| `OP-tftest` | mocked, `secrets_prevent_destroy=false`, `skip_port_ready_wait=true` | The unit-test suite (no creds). | ✅ (CI) |
| `OP-backup` | `backup_enabled=true`, cross-provider `BACKUP_AWS_*` | DR: tfstate + kube/talosconfig to primary + `-backup` replica. | ⬜ |

## C) Priority (highest-value untested, real apply)

1. **`OVH-vip`** — vip mode never applied on OVH (distinct Neutron `allowed_address_pairs` mechanism). `SCW-vip` is now ✅ (see findings below).
2. **Cloud HA multi-AZ** (`SCW-mgmt-ha`, `OVH-mgmt-ha`, `OSC-mgmt-ha`) — 3-CP etcd across zones never applied.
3. **Proxmox real apply** (`PMX-*`) — never run on a real host; needs a PVE host.
4. **OVH / Outscale real apply** — provider modules only unit-mocked.
5. **Workload role real apply** (`*-work-*`) — only management exercised.
6. **`OP-autotunnels`** — untested on a real host.
7. **`worker_storage` real apply** (`*-storage`) — LUKS2 `UserVolumeConfig` + block-volume attach never applied.
8. **`OP-failover` / `OP-backup`** cross-provider — DR path unproven.

## Findings — `SCW-vip` real apply (2026-07-15)

Applied 3 CP (fr-par-1 + fr-par-2 + fr-par-2) + 1 worker, `k8s_lb_mode=vip`.

- ✅ **Layer2 VIP works on Scaleway, including cross-zone.** The Talos ARP-announced
  VIP (`scaleway_ipam_ip.k8s_vip`, a private IPAM address) fronts the apiserver with
  no LB; `kubectl get nodes` through the VIP returns all nodes Ready with CPs split
  across fr-par-1 and fr-par-2. The regional private network relays the VIP's ARP
  across zones — the main open question going in, now answered.
- ✅ **VIP is in the apiserver cert SANs** (`modules/talos` adds it) — verified with
  `kubectl --tls-server-name <vip>`.
- ⚠️ **Operator access is private-only:** the apiserver lives on the private VIP, so
  `kubectl` needs the bastion 6443 tunnel that `talos-tunnels.sh` opens for vip mode.
- ⚠️ **`data.talos_cluster_health` can hang the two-phase apply in vip mode:** the
  health read is issued from the operator's machine and cannot reach the private VIP
  directly, so `task bootstrap-phase2` may block on it even though the cluster is
  healthy. etcd/config are applied before that read, so the state is complete; a
  follow-up improvement is to route the health check through the tunnel (or make it
  best-effort in vip mode).
- 🐛 **Fixed en route:** `talos-tunnels.sh` failed to drop a stale *hashed* bastion
  host key on IP reuse — now pinned in a dedicated per-run known_hosts (commit
  `fix(tunnels): pin the bastion in a dedicated, per-run known_hosts`).

## D) Keeping this current

1. **This committed doc** is the living artifact; keep the per-case **Status** column up to date.
2. **Generate the "shipped combos" rows from `envs/*.tfvars.example`** — a small `scripts/dev/gen-test-matrix.sh` can parse each example for the active `node_distribution.<provider>` block (`control_planes`/`workers`/`k8s_lb_mode`/zones/`enable_bastion`/`worker_storage`) so the table never drifts. Keep the hand-written excluded/priority prose above the generated table.
3. **Bind status to the `tofu test` filters** (`k8s-lb-mode`, `proxmox`, `scaleway`, `provider-contract`, `talos-config`) so "covered (unit)" vs "covered (apply)" is explicit; add filters as new dimensions land (`ovh`, `outscale`, `worker-storage`).
4. **CI drift guard**: fail if a new `node_distribution` field or a new `k8s_lb_mode`/`cluster_role` enum value appears in `variables.tf` without a matching row here.
