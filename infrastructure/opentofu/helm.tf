# ==============================================================================
# Kubernetes & Helm Providers
# Configured only when admin LB is enabled (bootstrap/maintenance mode)
# ==============================================================================

provider "kubernetes" {
  config_path = var.admin_lb_enabled ? "${path.root}/kubeconfig" : null
}

provider "helm" {
  kubernetes = {
    config_path = var.admin_lb_enabled ? "${path.root}/kubeconfig" : null
  }
}

# ==============================================================================
# Cilium CNI
# ==============================================================================

resource "helm_release" "cilium" {
  count = var.admin_lb_enabled ? 1 : 0

  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.16.5"
  namespace  = "kube-system"

  values = [
    yamlencode({
      ipam = {
        mode = "kubernetes"
      }
      kubeProxyReplacement = true
      cgroup = {
        autoMount = { enabled = false }
        hostRoot  = "/sys/fs/cgroup"
      }
      securityContext = {
        capabilities = {
          ciliumAgent      = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
          cleanCiliumState = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
        }
      }
      k8sServiceHost = try(module.scw[0].admin_lb_ip, "127.0.0.1")
      k8sServicePort = 6443
      hubble = {
        enabled = false
      }
      operator = {
        replicas = 1
      }
    })
  ]

  wait    = true
  timeout = 600

  depends_on = [local_file.kubeconfig]
}

# ==============================================================================
# ArgoCD (Management Tier)
# ==============================================================================

resource "helm_release" "argocd" {
  count = var.admin_lb_enabled ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.11"
  namespace        = "management-gitops"
  create_namespace = true

  values = [
    file("${path.module}/helm-values/argocd.yaml")
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  depends_on = [helm_release.cilium]
}

# ==============================================================================
# Outputs
# ==============================================================================

output "argocd_status" {
  value = var.admin_lb_enabled ? {
    namespace = helm_release.argocd[0].namespace
    version   = helm_release.argocd[0].version
    status    = helm_release.argocd[0].status
  } : null
  description = "ArgoCD deployment status (null when admin LB disabled)"
}
