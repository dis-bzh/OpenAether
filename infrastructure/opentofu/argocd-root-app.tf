# ArgoCD Root Application Deployment
# The root "App of Apps" is deployed as a server.additionalApplications
# in the ArgoCD Helm values, making it fully declarative.
# If a separate YAML manifest is needed post-bootstrap, apply manually:
#   kubectl apply -f apps/bootstrap/overlays/prod/root-app.yaml --kubeconfig=./kubeconfig

output "argocd_root_app_status" {
  value       = var.admin_lb_enabled ? "ArgoCD root application deployed via Helm values" : "Admin LB disabled — ArgoCD manages itself via GitOps"
  description = "Status of ArgoCD root application deployment"
}
