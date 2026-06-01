# Apps (`apps/`)

Kubernetes manifests managed by ArgoCD (GitOps). All workloads are defined here
and deployed to the appropriate clusters by the ArgoCD ApplicationSet on the
management cluster.

## Multi-cluster Routing

The ArgoCD ApplicationSet (`bootstrap/overlays/prod/root-appset.yaml`) routes
deployments based on the `openaether.io/role` label on each cluster secret:

| Label value | Overlay deployed | Cluster type |
|-------------|-----------------|--------------|
| `management` | `overlays/management/` | Management hub (OpenBao, Keycloak, VictoriaMetrics) |
| `workload` | `overlays/workload-base/` | Spoke clusters (client apps) |

## Directory Structure

### `base/` — Provider-agnostic definitions

All manifests here are environment-agnostic and runnable on any cluster.

| Service | Directory | Status |
|---------|-----------|--------|
| Namespaces | `base/namespaces/` | ✅ |
| Traefik (Gateway API) | `base/traefik/` | ✅ |
| OpenBao (secrets) | `base/openbao/` | ✅ Management only |
| Keycloak + CNPG | `base/keycloak/`, `base/cnpg/` | ✅ Management only |
| External Secrets | `base/external-secrets/` | ✅ All clusters |
| Kyverno + policies | `base/kyverno/`, `base/kyverno-policies/` | ✅ All clusters |
| KEDA (autoscaling) | `base/keda/` | ✅ Workload clusters |
| VictoriaMetrics + Grafana | `base/observability/` | ✅ Management only |
| Storage (local-path) | `base/storage/` | ✅ All clusters |
| Linkerd | `base/linkerd/` | ⚠️ Deprecated → replacing with Cilium SM (Phase 4) |
| ArgoCD hub config | `base/argocd-hub/` | 🚧 Phase 4 |

### `overlays/` — Environment-specific configurations

```
overlays/
├── management/        # Management cluster: OpenBao, Keycloak, Grafana, ...
├── workload-base/     # Workload cluster base: Traefik, ESO, Kyverno, KEDA, ...
├── local/             # Local development: dev mode, single replicas
└── prod/              # Legacy: single-cluster production (pre-Phase 3)
```

### `bootstrap/` — ArgoCD bootstrap manifests

Applied once at cluster creation via Talos `inlineManifests`. Do NOT apply
manually unless the initial bootstrap failed.

```
bootstrap/overlays/prod/
├── root-appset.yaml          # ApplicationSet — deploys overlays to all clusters
├── local-cluster-secret.yaml # Registers the management cluster in ArgoCD
└── argocd-cmd-params-cm.yaml # ArgoCD server configuration
```

**Bootstrap flow:**
1. `tofu apply ... -var talos_bootstrap=true` → Talos injects ArgoCD + root app via inlineManifests
2. ArgoCD boots → syncs `apps/bootstrap/overlays/prod/`
3. ApplicationSet discovers registered clusters → deploys appropriate overlay to each
4. Management cluster gets `overlays/management/`, workload clusters get `overlays/workload-base/`

## Adding a New Workload Cluster

```bash
# 1. Provision the cluster
task deploy-workload PROVIDER=ovh

# 2. Bootstrap Talos
task bootstrap-workload PROVIDER=ovh

# 3. Register in ArgoCD hub (creates a cluster secret with openaether.io/role=workload)
task register-spoke CLUSTER=openaether-ovh-prod PROVIDER=ovh

# 4. ArgoCD automatically deploys overlays/workload-base/ to the new cluster
```

## Adding a New Service to the Platform

To add a service available on all workload clusters:
1. Add manifests to `apps/base/<service>/` with a `kustomization.yaml`
2. Add `- ../../base/<service>` to `apps/overlays/workload-base/kustomization.yaml`
3. Commit and push → ArgoCD ApplicationSet deploys to all clusters automatically
