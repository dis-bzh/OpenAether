# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.3.0] — 2026-05-30

### Added — Local 3-CP Talos test harness (Docker)

- **`infrastructure/opentofu-local/`** — standalone OpenTofu root (no S3 backend) that drives the **production `modules/talos/`** to stand up a real **3 control plane** Talos cluster in Docker.
- **`modules/providers/local/`** — Docker-based provider (terraform_data + Docker CLI, no Docker provider dependency): N containers on a dedicated `10.5.0.0/24` network with static IPs, `--read-only`, `PLATFORM=container`, the full Talos volume set, and config injected via `USERDATA`. Implements the provider contract with a node-IP / host-endpoint split (`127.0.0.1` port mappings for WSL2).
- **`modules/talos/` enhancements (backward-compatible, cloud unchanged):**
  - `config_delivery` (`apply` cloud / `userdata` Docker) — Docker uses USERDATA injection per the Talos platform docs (maintenance-apply reboot-loops in containers).
  - `control_plane_endpoints` / `worker_endpoints` — reach nodes via port mappings while keeping container IPs as node identity (etcd/certSANs).
  - `container_mode` — omits `machine.install` and enables `hostDNS.forwardKubeDNSToHost`.
  - `health_check_timeout`, `skip_kubernetes_health_checks`, `skip_health_check` — robustness knobs.
  - New outputs `control_plane_machine_configs` / `worker_machine_configs` (consumed for USERDATA).
- **`scripts/test-talos-local.sh`** — single-command E2E: config gen → 3 USERDATA containers → etcd quorum bootstrap → kubeconfig → Cilium (3 nodes) → ArgoCD → ApplicationSet.
- **`render-bootstrap-manifests.sh --local`** — simplified Cilium (no WireGuard, no kube-proxy replacement) for Docker.
- **Taskfile** `local-*` tasks.
- **Validated end-to-end**: 3 nodes `Ready` on Kubernetes v1.35.3, **3-member etcd quorum**, Cilium CNI on all nodes, tofu-retrieved kubeconfig, ArgoCD running, and the ApplicationSet generating the management cluster's Application.
- **Coverage**: 7 of 8 `modules/talos/` resources are exercised locally; only `talos_machine_configuration_apply` and the `talos_cluster_health` data source are cloud-only (both for legitimate platform/networking reasons).

### Added

**Multi-cloud CMP infrastructure (Phase 3):**
- **OVH / OpenStack module** — complete networking stack (private network, router, Octavia LBs, floating IPs, bastion)
- **Outscale / Numspot module** — VPC, subnets, load balancers, public IPs, bastion
- **Provider-agnostic junction point** — `coalesce()` selects the active provider; adding a new provider requires only implementing the contract
- **`cluster_role` variable** — `management` or `workload` routes ArgoCD to the correct overlay
- **Per-cluster environment templates** — `envs/management-scw.tfvars.example`, `envs/workload-{scw,ovh,outscale}.tfvars.example`, `envs/drp-ovh.tfvars.example` (copy to the real `*.tfvars`, which stays git-ignored)
- **Single-provider validation** — `check` block prevents accidentally activating multiple providers in one apply

**GitOps multi-cluster:**
- **ArgoCD ApplicationSet** — replaces single root Application; automatically deploys the correct overlay to each registered cluster
- **Management cluster overlay** — `apps/overlays/management/` (OpenBao, Keycloak, VictoriaMetrics, etc.)
- **Workload cluster overlay** — `apps/overlays/workload-base/` (Traefik, ESO, Kyverno, KEDA, storage)
- **Local cluster secret** — management cluster registers itself in ArgoCD hub on bootstrap

**Operational tooling:**
- **`scripts/register-spoke.sh`** — registers a workload cluster in ArgoCD hub after provisioning
- **`scripts/drp-management.sh`** — automated DRP procedure; rebuilds management cluster on fallback provider (~30 min RTO)
- **`scripts/test-local-stack.sh`** — full local validation (OpenTofu tests + kustomize builds + talosctl + yamllint) with no cloud credentials required
- **Taskfile** — new tasks: `deploy-management`, `deploy-workload`, `bootstrap-workload`, `register-spoke`, `drp`

**Testing (26 unit tests):**
- `tests/scaleway.tftest.hcl` — 9 tests (SCW module, provider contract, multi-provider activation)
- `tests/talos-config.tftest.hcl` — 10 tests (certSANs, bootstrap logic, version format, cluster role)
- `tests/provider-contract.tftest.hcl` — 7 tests (junction point behavior, all 3 providers, safe defaults)

**CI enhancements:**
- OpenTofu tests run all 3 test suites
- Kustomize build validation for all 6 overlays
- Talos config generation and validation via `talosctl`

### Changed

- `node_distribution` variable extended with OVH/Outscale-specific optional fields (`flavor_name`, `availability_zones`, `network_name`, `bastion_image_id`)
- `outputs.tf` — all outputs are now provider-agnostic; added `active_provider` and `cluster_role`
- `argocd-root-app.yaml.tftpl` — now points to `apps/bootstrap/overlays/prod/` instead of a single overlay path
- `apps/overlays/local/` — removed deprecated Linkerd (replaced by Cilium Service Mesh, Phase 4)
- YAML lint config — added ignore patterns for vendor/generated files; relaxed sequence indentation rule

### Fixed

- `apps/base/namespaces/` — missing `kustomization.yaml` (kustomize build was failing)
- `apps/base/kyverno-policies/` — missing `kustomization.yaml`
- `apps/base/openbao/statefulset.yaml` — indentation errors
- `apps/base/openbao/httproute.yaml` — indentation errors
- `apps/base/traefik/rbac-gateway.yaml` — lines exceeding 120 chars
- Grafana — disabled anonymous admin access (was `GF_AUTH_ANONYMOUS_ENABLED=true`)

### Updated (versions)

| Component | Before | After |
|-----------|--------|-------|
| VictoriaMetrics | v1.93.0 | v1.102.0 |
| Grafana | 10.0.0 | 11.2.0 |
| OpenBao | 2.0.0 | 2.2.0 |
| KEDA | v2.12.0 | v2.15.1 |
| Kyverno | v1.10.0 | v1.12.0 |
| kubectl (Kyverno CronJob) | v1.28.2 | v1.33.0 |
| busybox (storage) | unpinned | 1.36.1 |

---

## [0.2.0] — 2026-02-01

- **Secure Remote Management**: Encrypted S3 Backend for Tofu state (Client-Side Encryption, AES-GCM).
- **Automated SSE-C Backups**: Secure artifact backup (`kubeconfig`, configurations) to S3.
- **Zero-Trust Networking**: Refactored LB ACLs (admin IP + NAT GW hairpinning).
- **Scaleway Deployment**: First provider deployed and validated in HA environment.
- **Zero-Local Policy**: No persistent local configuration files.

### Infrastructure

- Scaleway: Security Groups with zonal segmentation.
- Scaleway: Hybrid zone support for `DEV1-S` / `PRO2` instance types.

---

## [0.1.0] — 2025-12-31

- Multi-provider architecture (Outscale, Scaleway)
- Talos Linux v1.9.1, Pulumi (Go) IaC
- Cilium CNI auto-deployment
- Taskfile automation
- GitOps structure prepared (`apps/`)
