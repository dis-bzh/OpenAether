variable "cluster_name" {
  type    = string
  default = "openaether-local"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cluster_role" {
  type    = string
  default = "management"
}

variable "talos_version" {
  type    = string
  default = "v1.12.6"
}

variable "kubernetes_version" {
  type    = string
  default = "v1.35.3"
}

variable "talos_bootstrap" {
  description = "Phase 2: bootstrap the cluster (containers + etcd + kubeconfig). Set to true for a full cluster; false generates config only."
  type        = bool
  default     = false
}

variable "control_plane_count" {
  description = "Number of control plane containers (3 for a real etcd quorum, 1 for a quick smoke test)"
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 or 3 for a valid local quorum."
  }
}

variable "git_repo_url" {
  type    = string
  default = "https://github.com/dis-bzh/OpenAether.git"
}

variable "argocd_namespace" {
  type    = string
  default = "management-gitops"
}

# Accept cilium manifest override (for local simplified variant)
variable "cilium_manifest" {
  description = "Cilium manifest content. Set via TF_VAR_cilium_manifest from cilium-local.yaml."
  type        = string
  default     = null
}
