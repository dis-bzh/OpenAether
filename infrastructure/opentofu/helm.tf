# Helm and Kubernetes Provider Configuration
# Uses the public Load Balancer endpoint for operations
# Note: Providers will only work once the cluster is fully bootstrapped (Cilium up -> LB healthy)

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}

# Provider alias for generating manifests locally without cluster connection
provider "helm" {
  alias = "manifest_generator"
  # No kubernetes block needed for local rendering
}

# ------------------------------------------------------------------------------
# ArgoCD (Management Tier)
# ------------------------------------------------------------------------------
# Note: Namespace management-gitops is managed by ArgoCD via apps/base/namespaces/

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"
  namespace  = "management-gitops"
  
  create_namespace = false

  values = [
    file("${path.module}/helm-values/argocd.yaml")
  ]

  # Wait for ArgoCD to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # Dependencies
  depends_on = [
    talos_machine_bootstrap.this,
    null_resource.apply_namespaces
  ]
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "argocd_status" {
  value = {
    namespace = helm_release.argocd.namespace
    version   = helm_release.argocd.version
    status    = helm_release.argocd.status
  }
  description = "ArgoCD deployment status"
}
