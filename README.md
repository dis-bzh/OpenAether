# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> An idempotent Talos cluster on any environment — local (Docker), on-prem
> (Proxmox) or cloud (Scaleway/OVH/Outscale) — with a single fixed foundation:
> **CNI (Cilium) + Flux**. Everything else is picked from `OpenAether-apps`.

🇫🇷 [Version française](README.fr.md)

## Version

**v0.4.0+** — modular multi-provider Talos foundation (see `CLAUDE.md` and
`CHANGELOG.md [Unreleased]`).

Management validated end-to-end on **Scaleway, OVH and Outscale**; local Docker
validated (3 CP + 3 workers); Proxmox is code-complete but **never applied on
real hardware**. Client-side-encrypted tfstate/artifact backups, dual store.
Active-active multi-cloud has been dropped; the CAPI hub/spoke is an
**optional layer**.

## Architecture

```
A standalone Talos cluster (fixed foundation: Cilium + Flux)
  └── modular pick from OpenAether-apps (scripts/pick.py):
      OpenBao, ESO, cert-manager/PKI, Istio ambient, gateway, CNPG,
      Longhorn, observability, Zitadel, Kyverno, restic backups…

OPTIONAL layer — management cluster (CAPI picked):
  Management (hub) ──CAPI+Talos──▶ client clusters (kubeception)
                    ──Flux kubeConfig──▶ Cilium+Flux injected remotely,
                    then each child reconciles ITS OWN git profile (gitception)
```

**Design principle:** the management cluster is **not** in the client data path.
If it becomes unavailable, client workloads keep running — each child has its
own Flux.

## Two ways to birth the first cluster

| Path | When | What it creates |
|---|---|---|
| **OpenTofu** (default) | Every ordinary case | The whole substrate: network, router, security groups, LB, bastion, volumes, S3 buckets — then Talos |
| **CAPI** (optional) | You want the management described like any other cluster, plus CAPI's day-2 tooling | A throwaway cluster creates the management, which then becomes self-managed (`clusterctl move`) |

The CAPI path **does not replace** OpenTofu: on OVH, OpenTofu creates ~44
resources of which only 3 are compute instances. Full procedure and pitfalls:
**[docs/capi-bootstrap.md](docs/capi-bootstrap.md)**.

## Layer status

| Layer | Technology | Status |
|-------|------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.x (immutable) | ✅ |
| **CNI** | Cilium 1.19.2 (WireGuard) | ✅ |
| **GitOps** | Flux v2.4.0 (hub/spoke) | ✅ |
| **Secrets** | OpenBao 2.5.4 (Vault fork) | ✅ validated on real cloud |
| **PKI** | cert-manager v1.15.3 | ✅ |
| **Gateway / Mesh** | Istio 1.24.2 (ambient + Gateway API) | ✅ |
| **Database** | CloudNativePG 1.23.1 | ✅ |
| **Storage** | Longhorn 1.9.2 | ✅ |
| **Identity** | Zitadel 10.0.2 | ✅ deployed — Grafana SSO pending a browser check |
| **Observability** | VictoriaMetrics operator 0.65.1, Loki 6.25.0, Grafana 8.6.4, Alloy 0.11.0 | ✅ |
| **Policy** | Kyverno v1.12.1 | ✅ |
| **Cluster API** | CAPI v1.13.2, CABPT v0.6.12, CACPPT v0.5.13, CAPS v0.2.1, CAPO v0.14.4, CAPOSC v1.5.0 | ✅ optional layer |

## Providers

One contract for all (`modules/providers/provider-contract.md`) — the
Talos/cluster stack is provider-agnostic. Details:
`docs/deployment-test-matrix.md`.

| Provider | Status | Region / target | Notes |
|----------|--------|-----------------|-------|
| **Scaleway** | ✅ management validated | fr-par (3 AZs) | Reference implementation; rolling-replace exercised live |
| **OVH** | ✅ management validated | EU-WEST-PAR (OpenStack) | Octavia LB, floating IPs, SNAT router, private network |
| **Outscale / Numspot** | ✅ management validated | eu-west-2 | LB, NAT service, public/private subnets, VPC |
| **Proxmox (on-prem)** | 🧪 code-complete, unit-tested — **never applied for real** | PVE single/multi-host | Talos VIP (no managed LB), host nftables NAT/DNAT, manual prerequisites |
| **Local (Docker)** | ✅ validated (`task local-up`) | WSL2 / Docker | 3 CP + 3 workers, etcd quorum, Cilium — credential-free proof of `modules/talos` |

## Repository structure

```
infrastructure/opentofu/
  cluster/        # cluster root (management + workload); envs/ = one tfvars per cluster
  talos-image/    # image builder, its own state
  opentofu-local/ # local Docker root, reuses modules/talos
  modules/talos/  # secrets, config, bootstrap — provider-agnostic
  modules/providers/{scw,ovh,outscale,proxmox,local}/   # provider-contract.md = the contract
scripts/
  bootstrap/  # lifecycle (rare)
  ops/        # day to day: fleet-down, edge-down, rolling-replace, etcd-snapshot,
              # preflight-quotas, check-cilium-parity, purge-orphans…
  internal/   # called by the Taskfile
```

Kubernetes manifests live in
[dis-bzh/OpenAether-apps](https://github.com/dis-bzh/OpenAether-apps).

## Quick start

### Prerequisites

```bash
./scripts/setup.sh          # tofu, talosctl, kubectl, task, helm, yamllint…

# CLOUD only — local testing needs no credentials at all.
cp .env.example .env.sh     # then edit it
source .env.sh              # git-ignored; also holds TF_VAR_encryption_passphrase
```

⚠️ **Always `source .env.sh` before any cloud-facing `task`.** Without it,
`tofu` prompts interactively for `var.encryption_passphrase` and the command
fails — including a teardown, which can then *look* successful while destroying
nothing.

### Local cluster (Docker — no cloud, no credentials)

Brings up a real **3 control plane + 3 worker** Talos cluster in Docker, on the
**same `modules/talos/` used in production**. Best first step.

```bash
task local-up        # full deploy
task local-status    # etcd members + nodes + Flux
task local-down      # tear down (containers + volumes + state)
```

⚠️ **On Windows/WSL2**: Hyper-V reserves blocks of ports above 49152, and those
blocks move across reboots. The host port base is therefore configurable
(`talos_api_port_base`, default 41000). Diagnose with
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

### Management cluster (cloud)

```bash
source .env.sh

cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
# Edit: admin_ip, bastion_ssh_keys, image_name/image_id, s3_primary_*/s3_replica_*

task preflight-quotas PROVIDER=ovh          # check quotas first
task talos-image PROVIDER=scaleway          # once per image version
task infra ROLE=management PROVIDER=scaleway
task bootstrap-phase2 ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

**After deployment**: follow the day-1 path
([docs/admin-access.md](docs/admin-access.md)) — Shamir/root/restic
escrow, offline signing of the PKI intermediate, seeding the backup
destinations, admin access to the UIs, CAPI child secrets.

### Teardown

Order matters: the management owns its children's CRs.

```bash
source .env.sh
task edge-down CLUSTER=edge-1 -- --yes      # each CAPI child first
task fleet-down PROVIDER=ovh -- --yes       # then the management
python3 scripts/ops/purge-orphans/ovh.py    # dry-run: confirm nothing is left
```

⚠️ Floating IPs pre-allocated outside OpenTofu do not disappear on their own,
and a **self-managed** cluster cannot finish deleting itself
(see `docs/capi-bootstrap.md`).

### Emulated cloud (Feint — no cloud account, no credentials)

Points the **real** Scaleway and Outscale providers at a local emulator of their
APIs. One step past the mocked `tofu test`: real HTTP, real decode, no bill.

```bash
task feint-up                        # start the emulator (pinned binary, checksum-verified)
task feint-plan  PROVIDER=scaleway   # plan the REAL cluster root, zero credentials
task feint-apply PROVIDER=outscale   # apply/destroy cycle on the reduced fixture
task feint-down
```

⚠️ It does **not** prove a real deployment works — the emulator has no
inventory, no load balancer and no quotas. See
[docs/emulated-cloud.md](docs/emulated-cloud.md).

### Static checks (no cloud, no Docker)

```bash
task validate            # tofu fmt/validate/test
task apps-validate       # Flux DAG integrity + pick.py profiles up to date
task security            # hardening checks
```

## Documentation

| File | Contents |
|---|---|
| [docs/admin-access.md](docs/admin-access.md) | Day-1 path: escrow, offline PKI, UI access, browser tests |
| [docs/capi-bootstrap.md](docs/capi-bootstrap.md) | Bootstrap a management via CAPI and make it self-managed |
| [docs/deployment-test-matrix.md](docs/deployment-test-matrix.md) | What is validated, where, and how |
| [docs/emulated-cloud.md](docs/emulated-cloud.md) | Testing Scaleway/Outscale against a local emulator — and the limits of that |
| [docs/backlog.md](docs/backlog.md) | **Source of truth**: current state, debt, improvements (French only — living working document) |

## Security

| Control | Implementation |
|---------|----------------|
| No public IPs on cluster nodes | VPC-only, bastion SSH tunnel |
| Bastion SSH | Dedicated unprivileged user, key-only (root login and passwords disabled) |
| State encryption | Client-side AES-GCM + PBKDF2 (`encryption{}`) before S3 |
| Artifact encryption | Client-side authenticated gpg AES-256, plus S3 SSE on top |
| Replication / DR | State and artifacts mirrored to a `-backup` store (prod: a different provider, separate credentials) |
| Kubernetes API access | LB ACL restricted to `admin_ip` |
| Talos API access | SSH tunnel only (port 50000, never on the LB) |
| Inter-node encryption | Cilium WireGuard |
| Secrets management | OpenBao (Vault fork, open source) |

## Roadmap

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **3** | OVH + Outscale active, Flux hub/spoke, cross-provider failover | ✅ done |
| **3b** | CAPI-bootstrapped management + self-managed pivot | ✅ done |
| **4** | `providerID` on CAPI nodes (CCM or kubelet) → MachineHealthCheck | ⏳ priority |
| **4b** | DNS failover (ExternalDNS + k8GB), OpenBao auto-unseal | ⏳ planned |
| **5** | Service catalogue (Kratix / Backstage) | ⏳ planned |

## License

**OpenAether** is licensed under the
[GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source: **https://github.com/dis-bzh/OpenAether-infra**
