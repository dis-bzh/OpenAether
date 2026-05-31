variable "backup_enabled" {
  description = "Whether to backup cluster artifacts to S3. Disable for local testing."
  type        = bool
  default     = true
}

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

variable "cluster_role" {
  description = "Role of this cluster in the CMP: 'management' (hub, runs ArgoCD/OpenBao/Keycloak) or 'workload' (spoke, runs client apps)"
  type        = string
  default     = "workload"
  validation {
    condition     = contains(["management", "workload"], var.cluster_role)
    error_message = "cluster_role must be 'management' or 'workload'."
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
  description = <<-EOT
    Distribution of nodes per provider. At most one provider may have count > 0 per apply.
    Keys: "scaleway", "ovh", "outscale".

    Common fields (all providers):
      control_planes, workers, region, image_id, image_name

    Scaleway-specific:
      zone            - primary zone (e.g. "fr-par-1")
      zones           - multi-AZ list for HA (e.g. ["fr-par-1", "fr-par-2", "fr-par-3"])
      instance_type   - VM type (e.g. "DEV1-M")

    OVH-specific:
      flavor_name         - OpenStack flavor (e.g. "b2-7")
      network_name        - External network name for floating IPs (default "Ext-Net")
      availability_zones  - OpenStack AZ list (default ["nova"])

    Outscale-specific:
      instance_type      - VM type (e.g. "tinav5.c2r4p1")
      availability_zones - Subregion list (e.g. ["eu-west-2a", "eu-west-2b"])

    Local/Docker-specific (key "local"):
      talos_api_port  - Host port mapped to container port 50000 (default 50000)
      k8s_api_port    - Host port mapped to container port 6443 (default 6443)
  EOT
  type = map(object({
    control_planes     = number
    workers            = number
    region             = optional(string)
    zone               = optional(string)
    zones              = optional(list(string))
    instance_type      = optional(string)
    flavor_name        = optional(string)
    image_id           = optional(string)
    image_name         = optional(string, "talos")
    availability_zones = optional(list(string))
    network_name       = optional(string, "Ext-Net")
    bastion_image_id   = optional(string)
    talos_api_port     = optional(number, 50000)
    k8s_api_port       = optional(number, 6443)
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

variable "cilium_manifest" {
  description = "Optional override for Cilium manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "argocd_manifest" {
  description = "Optional override for ArgoCD manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "root_app_manifest" {
  description = "Optional override for Root App manifest (rendered from template by default)"
  type        = string
  default     = null
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
