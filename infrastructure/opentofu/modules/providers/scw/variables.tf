variable "cluster_name" {
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
  description = "ID of the Talos image/snapshot"
}

variable "control_plane_config" {
  type        = string
  description = "Talos machine config for control plane"
}

variable "worker_config" {
  type        = string
  description = "Talos machine config for worker"
}

variable "admin_ip" {
  type        = string
  description = "IP de l'administrateur pour whitelist"
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
