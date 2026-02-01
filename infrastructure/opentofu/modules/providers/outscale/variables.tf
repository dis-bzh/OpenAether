variable "cluster_name" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "instance_type" {
  type    = string
  default = "tinav5.c2r4p1"
}

variable "image_id" {
  type        = string
  description = "OMI ID for Talos"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID"
  default     = null # Optional if default VPC
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

variable "control_plane_count" {
  type    = number
  default = 0
}

variable "worker_count" {
  type    = number
  default = 0
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
