variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
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

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one BSU volume
    attached to EVERY worker (worker × disk matrix). `volumes` is consumed by
    modules/talos (UserVolumeConfig), not here. Empty = no extra disks.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(any, [])
  })
  default = { disks = [], volumes = [] }
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

variable "bastion_ssh_keys" {
  description = "SSH public keys for bastion access (list for multi-admin)"
  type        = list(string)
  default     = []
}

variable "bastion_image_id" {
  description = "Image ID for the bastion host"
  type        = string
  default     = null
}

variable "bastion_vm_type" {
  description = "VM type for the bastion host (jump box; the default is the minimum recommended)."
  type        = string
  default     = "tinav5.c2r2p2"
}
