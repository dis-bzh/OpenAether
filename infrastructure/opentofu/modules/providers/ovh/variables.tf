variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "OVH/OpenStack region"
  type        = string
  default     = "EU-WEST-PAR"
}

variable "flavor_name" {
  description = "OpenStack flavor for cluster nodes"
  type        = string
  default     = "b3-8"
}

variable "image_id" {
  description = "OpenStack image ID for Talos Linux"
  type        = string
}

variable "network_name" {
  description = "Network name for instances (usually Ext-Net for public)"
  type        = string
  default     = "Ext-Net"
}

variable "network_id" {
  description = "Network ID for port-based networking (required for LB VIP)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for LB members (required for Octavia)"
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "Availability zones for node distribution"
  type        = list(string)
  default     = ["nova"]
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

# Security
variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API)"
  type        = list(string)
}

variable "bastion_ssh_keys" {
  description = "SSH public keys for bastion access (list for multi-admin)"
  type        = list(string)
  default     = []
}

variable "bastion_image_id" {
  description = "Image ID or name for the bastion host"
  type        = string
  default     = "Ubuntu 22.04"
}
