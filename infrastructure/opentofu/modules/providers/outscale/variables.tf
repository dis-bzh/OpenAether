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

variable "control_plane_count" {
  type    = number
  default = 0
}

variable "worker_count" {
  type    = number
  default = 0
}

variable "control_plane_config" {
  type = string
}

variable "worker_config" {
  type = string
}
