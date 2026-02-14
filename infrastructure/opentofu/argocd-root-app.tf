# ArgoCD Root Application Deployment
# Automatically deploys the "App of Apps" pattern after ArgoCD is ready

resource "null_resource" "argocd_root_app" {
  # Trigger re-apply if root app changes
  triggers = {
    root_app_hash = filemd5("${path.root}/../../apps/bootstrap/overlays/prod/root-app.yaml")
  }
  
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for ArgoCD to be ready
      echo "Waiting for ArgoCD to be ready..."
      kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server \
        -n management-gitops \
        --kubeconfig=${path.root}/kubeconfig
      
      # Apply root application
      echo "Deploying ArgoCD root application..."
      kubectl apply -f ${path.root}/../../apps/bootstrap/overlays/prod/root-app.yaml \
        --kubeconfig=${path.root}/kubeconfig
      
      echo "✅ ArgoCD root application deployed - GitOps is now active!"
    EOT
  }
  
  depends_on = [
    helm_release.argocd
  ]
}

output "argocd_root_app_status" {
  value = "ArgoCD root application will be deployed automatically"
  description = "Status of ArgoCD root application deployment"
}
