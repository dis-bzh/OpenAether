variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
  default     = "openaether"
}

variable "talos_version" {
  description = "Talos version to use"
  type        = string
  default     = "v1.9.3"
}

variable "kubernetes_version" {
  description = "Kubernetes version to use"
  type        = string
  default     = "v1.32.1"
}

variable "node_distribution" {
  description = "Distribution of nodes across providers"
  type = map(object({
    control_planes = number
    workers        = number
    region         = optional(string)
    zone           = optional(string)
    instance_type  = optional(string)
    image_id       = optional(string)
    image_name     = optional(string)
    zones          = optional(list(string))
    subnet_id      = optional(string)
  }))
  default = {}
}

variable "cluster_endpoint" {
  description = "Public endpoint for the cluster"
  type        = string
  default     = "openaether.local"
}

variable "admin_ip" {
  description = "List of allowed Source IPs/CIDRs for Admin Access (SSH, API)"
  type        = list(string)
}

variable "bastion_ssh_keys" {
  description = "Map de clés SSH publiques pour les bastions par provider"
  type        = map(string)
  default     = {}
}

variable "backup_s3_endpoint" {
  description = "S3 Endpoint for backups (e.g. https://s3.fr-par.scw.cloud)"
  type        = string
}

variable "backup_s3_region" {
  description = "S3 Region for backups (e.g. fr-par)"
  type        = string
}

variable "backup_s3_bucket" {
  description = "S3 Bucket name for backups"
  type        = string
}
