variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "Scaleway region (e.g. fr-par)"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Scaleway primary zone (e.g. fr-par-1)"
  type        = string
  default     = "fr-par-1"
}

variable "additional_zones" {
  description = "Zones for multi-AZ distribution of nodes"
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "project_id" {
  description = "Scaleway Project ID (null = provider default)"
  type        = string
  default     = null
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

variable "instance_type" {
  description = "Instance type for cluster nodes"
  type        = string
  default     = "DEV1-S"
}

variable "image_id" {
  description = "Talos image ID (zonal, overrides image_name)"
  type        = string
  default     = null
}

variable "image_name" {
  description = "Talos image name (looked up across zones)"
  type        = string
  default     = "talos"
}

# Security
variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API)"
  type        = list(string)
}

variable "bastion_ssh_key" {
  description = "SSH public key for bastion access"
  type        = string
}

variable "bastion_image_id" {
  description = "Image ID for the bastion host"
  type        = string
  default     = "ubuntu_jammy"
}
