# Bootstrap Manifests

Static Kubernetes manifests injected at cluster creation via **Talos `inlineManifests`**.

## Files

| File | Source | Injected when |
|------|--------|---------------|
| `cilium.yaml` | `helm template cilium/cilium` | Always (CNI is required) |
| `argocd-install.yaml` | Official ArgoCD `install.yaml` | `talos_bootstrap=true` (initial bootstrap only) |
| `argocd-root-app.yaml.tftpl` | OpenTofu template | `talos_bootstrap=true` (initial bootstrap only) |

## Regenerating Manifests

Run whenever upgrading Cilium or ArgoCD:

```bash
# Default versions (from script)
./scripts/render-bootstrap-manifests.sh

# Override versions
CILIUM_VERSION=1.20.0 ARGOCD_VERSION=v3.4.0 ./scripts/render-bootstrap-manifests.sh
```

Then commit the updated files. OpenTofu reads them at apply time.

## Current Versions

| Component | Version |
|-----------|---------|
| Cilium | 1.19.2 |
| ArgoCD | v3.3.2 |

## Bootstrap Flow

```
tofu apply -var talos_bootstrap=true
  └─► Talos control plane config
        └─► inlineManifests:
              ├── cilium.yaml              # CNI — nodes can communicate
              ├── argocd-install.yaml      # ArgoCD server + CRDs
              └── argocd-root-app          # Application → apps/bootstrap/overlays/prod/
                    └─► ArgoCD syncs bootstrap overlay
                          └─► ApplicationSet discovers clusters
                                ├── management cluster → apps/overlays/management/
                                └── spoke clusters    → apps/overlays/workload-base/
```

## ArgoCD Root App Template Variables

The `argocd-root-app.yaml.tftpl` template receives:
- `namespace` — ArgoCD namespace (default: `management-gitops`)
- `git_repo_url` — Repository URL
- `cluster_role` — `management` or `workload` (routes to correct overlay)

## Important Notes

- **Never commit real credentials** — these files contain no secrets
- **Cilium is always injected** — required for node networking before kubelet starts
- **ArgoCD is only injected on initial bootstrap** — on upgrades/DRP, ArgoCD already runs
  and manages itself via GitOps. Re-injecting would cause conflicts.
- **Upgrade path**: Update versions in `render-bootstrap-manifests.sh`, regenerate,
  then `tofu apply` with the new manifests
