variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
  default     = "openaether"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "talos_bootstrap" {
  description = "Whether to configure Talos via SSH tunnel (Phase 2). Default false (Phase 1 infra only)."
  type        = bool
  default     = false
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.12.0"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "v1.34.4"
}

variable "node_distribution" {
  description = "Distribution of nodes across providers (currently Scaleway only)"
  type = map(object({
    control_planes = number
    workers        = number
    region         = optional(string)
    zone           = optional(string)
    instance_type  = optional(string)
    image_id       = optional(string)
    image_name     = optional(string)
    zones          = optional(list(string))
  }))
  default = {}
}

variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API LB ACL)"
  type        = list(string)
}

variable "bastion_ssh_keys" {
  description = "Map of SSH public keys for bastion hosts, keyed by provider name"
  type        = map(string)
  default     = {}
}

# ==============================================================================
# GitOps / Bootstrap
# ==============================================================================

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD root application"
  type        = string
  default     = "https://github.com/dis-bzh/OpenAether.git"
}

variable "argocd_namespace" {
  description = "Namespace for ArgoCD installation"
  type        = string
  default     = "management-gitops"
}

# ==============================================================================
# S3 Backup
# ==============================================================================

variable "backup_s3_endpoint" {
  description = "S3 endpoint for backups (e.g. https://s3.fr-par.scw.cloud)"
  type        = string
}

variable "backup_s3_region" {
  description = "S3 region for backups"
  type        = string
}

variable "backup_s3_bucket" {
  description = "S3 bucket name for backups"
  type        = string
}
