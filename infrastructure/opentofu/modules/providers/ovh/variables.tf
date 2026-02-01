variable "cluster_name" {
  type = string
}

variable "region" {
  type    = string
  default = "GRA11"
}

variable "flavor_name" {
  type    = string
  default = "b2-7"
}

variable "image_id" {
  type        = string
  description = "OpenStack Image ID for Talos"
}

variable "network_name" {
  type    = string
  default = "Ext-Net" # Usually Ext-Net for public IPs
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

variable "network_id" {
  type        = string
  description = "ID of the network for the LB VIP (Required for Octavia)"
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for LB members (Required for Octavia)"
  default     = ""
}
