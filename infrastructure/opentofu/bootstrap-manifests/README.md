# Bootstrap Manifests

This directory contains the Kubernetes manifests injected at cluster bootstrap
via **Talos `inlineManifests`** in the control plane machine configuration.

## Files

| File | Source | Purpose |
|------|--------|---------|
| `cilium.yaml` | Generated via `helm template` | CNI — injected before kubelet starts |
| `argocd-install.yaml` | ArgoCD official `install.yaml` | ArgoCD server installation |
| `argocd-root-app.yaml.tftpl` | Template (OpenTofu) | Root Application that seeds GitOps |

## Generating / Updating Manifests

Run the render script to generate or update the static manifests:

```bash
../../scripts/render-bootstrap-manifests.sh
```

This downloads and renders:
- **Cilium**: `helm template` with Talos-specific values (no kube-proxy, kubePrism endpoint)
- **ArgoCD**: Official install manifest for the target version

### When to regenerate

- Upgrading Cilium version
- Upgrading ArgoCD version
- Changing Cilium configuration (e.g., enabling Hubble, WireGuard)

## Architecture

```
tofu apply
  └─► Talos machine config (control planes)
        └─► inlineManifests:
              ├── cilium.yaml          ← CNI bootstrap (Day 0)
              ├── argocd-install.yaml  ← ArgoCD installation (Day 0)
              └── argocd-root-app      ← Root App (templated, Day 0)
                    └─► ArgoCD manages everything else (Day 1+)
```

After bootstrap, **ArgoCD takes over** and manages all other workloads
defined in `apps/overlays/prod/`.
