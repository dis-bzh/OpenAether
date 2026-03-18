variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL (https://<lb_ip>:6443)"
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version (e.g. v1.12.0)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (e.g. v1.34.1)"
  type        = string
}

variable "control_plane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 0
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 0
}

variable "control_plane_ips" {
  description = "Private IPs of control plane nodes (used as Talos endpoints on 50000/TCP)"
  type        = list(string)
}

variable "worker_ips" {
  description = "Private IPs of worker nodes"
  type        = list(string)
}

variable "k8s_lb_ip" {
  description = "IP of the Kubernetes API load balancer (for certSANs)"
  type        = string
}

# ==============================================================================
# Bootstrap Manifests (injected via Talos inlineManifests)
# ==============================================================================

variable "cilium_manifest" {
  description = "Cilium CNI manifest YAML content (from bootstrap-manifests/cilium.yaml)"
  type        = string
}

variable "argocd_manifest" {
  description = "ArgoCD install manifest YAML content (from bootstrap-manifests/argocd-install.yaml)"
  type        = string
}

variable "root_app_manifest" {
  description = "ArgoCD root Application manifest YAML content (rendered from template)"
  type        = string
}
