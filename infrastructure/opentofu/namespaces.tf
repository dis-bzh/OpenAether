# Namespace Bootstrap
#
# This resource applies the GitOps-managed namespaces before Helm deployments
# This ensures foundation-networking and management-gitops exist for Cilium and ArgoCD

resource "null_resource" "apply_namespaces" {
  # Trigger re-apply if namespace definitions change
  triggers = {
    namespaces_hash = filemd5("${path.root}/../../apps/base/namespaces/namespaces.yaml")
  }
  
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for kubeconfig to be available on disk
      while [ ! -f "${path.root}/kubeconfig" ]; do
        echo "Waiting for kubeconfig file..."
        sleep 2
      done
      
      # Wait for API server to be responsive via the tunnel
      echo "Waiting for Kubernetes API to be responsive on 127.0.0.1:50000..."
      for i in {1..60}; do
        if kubectl cluster-info --kubeconfig=${path.root}/kubeconfig >/dev/null 2>&1; then
          echo "✅ Kubernetes API is ready"
          break
        fi
        echo "Still waiting for API..."
        sleep 5
        if [ $i -eq 60 ]; then
          echo "❌ Timeout waiting for Kubernetes API"
          exit 1
        fi
      done

      # Apply namespace definitions
      kubectl apply -f ${path.root}/../../apps/base/namespaces/namespaces.yaml \
        --kubeconfig=${path.root}/kubeconfig
      
      echo "✅ Namespaces applied successfully"
    EOT
  }
  
  depends_on = [
    talos_cluster_kubeconfig.this
  ]
}
