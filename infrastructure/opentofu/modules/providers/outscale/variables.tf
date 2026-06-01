variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "Outscale region"
  type        = string
  default     = "eu-west-2"
}

variable "instance_type" {
  description = "VM type for cluster nodes"
  type        = string
  default     = "tinav5.c2r4p1"
}

variable "image_id" {
  description = "OMI ID for Talos Linux"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for node placement"
  type        = string
  default     = null
}

variable "availability_zones" {
  description = "Availability zones for node distribution"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
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

variable "bastion_ssh_key" {
  description = "SSH public key for bastion access"
  type        = string
}

variable "bastion_image_id" {
  description = "Image ID for the bastion host"
  type        = string
  default     = null
}
