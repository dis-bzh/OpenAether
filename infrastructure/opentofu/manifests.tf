# Generate Cilium Manifests via Helm Template
# This allows Talos to bootstrap the CNI directly (inlineManifests)
# removing the need for an external Helm install via SSH tunnel.

data "helm_template" "cilium" {
  provider   = helm.manifest_generator
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.16.5"
  namespace  = "foundation-networking"
  
  kube_version = "1.35.0" # Simulate K8s version for template generation

  # Include CRDs in the generated manifest
  include_crds = true

  values = [
    file("${path.module}/helm-values/cilium.yaml")
  ]
}
