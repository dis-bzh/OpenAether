variable "cluster_name" {
  type = string
}

variable "machine_secrets" {
  description = "Talos machine secrets"
  sensitive   = true
}

variable "cluster_endpoint" {
  type = string
}

variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "region" {
  type    = string
  default = "fr-par"
}

variable "zone" {
  type    = string
  default = "fr-par-1"
}

variable "additional_zones" {
  type    = list(string)
  default = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "project_id" {
  type        = string
  description = "Scaleway Project ID"
  default     = null # If null, uses provider default
}

variable "control_plane_count" {
  type    = number
  default = 0
}

variable "worker_count" {
  type    = number
  default = 0
}

variable "instance_type" {
  type    = string
  default = "DEV1-S"
}

variable "image_id" {
  type        = string
  description = "ID of the Talos image (zonal)"
  default     = null
}

variable "image_name" {
  type        = string
  description = "Name of the Talos image (to find across zones)"
  default     = "talos"
}

# Config will be generated locally in config.tf

variable "admin_ip" {
  type        = list(string)
  description = "List of allowed Source IPs/CIDRs for Admin Access (SSH, API)"
}

variable "bastion_ssh_key" {
  type        = string
  description = "Clé SSH publique pour le bastion"
}

variable "bastion_image_id" {
  type        = string
  description = "Image ID pour le bastion (Ubuntu/Debian)"
  default     = "ubuntu_jammy" # Ubuntu 22.04 LTS
}

variable "extra_manifests" {
  type        = list(string)
  description = "List of extra manifests to directy inject into Talos configuration (e.g. CNI)"
  default     = []
}
