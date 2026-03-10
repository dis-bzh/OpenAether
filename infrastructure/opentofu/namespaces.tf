# Namespace Bootstrap
# Ensures namespaces exist before Helm chart deployments (Cilium, ArgoCD)
# Uses the Kubernetes provider declaratively — no scripts

resource "kubernetes_namespace_v1" "management_gitops" {
  count = var.admin_lb_enabled ? 1 : 0

  metadata {
    name = "management-gitops"
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
    }
  }

  depends_on = [helm_release.cilium]
}
