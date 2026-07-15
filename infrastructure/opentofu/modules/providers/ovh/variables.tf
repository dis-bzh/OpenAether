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
  description = "OpenStack (Glance) image UUID for Talos Linux. Null (default) looks it up by image_name instead — the name the talos-image root publishes under."
  type        = string
  default     = null
}

variable "image_name" {
  description = "Glance image name to look up when image_id is null (most recent match)."
  type        = string
  default     = "talos"
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one Cinder block
    volume attached to EVERY worker (worker × disk matrix). `volumes` is consumed
    by modules/talos (UserVolumeConfig), not here. Empty = no extra disks.
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(any, [])
  })
  default = { disks = [], volumes = [] }
}

variable "network_name" {
  description = "Network name for instances (usually Ext-Net for public)"
  type        = string
  default     = "Ext-Net"
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

variable "bastion_flavor_name" {
  description = "OpenStack flavor for the bastion host (jump box; the default is the minimum recommended)."
  type        = string
  default     = "b3-8"
}

variable "k8s_lb_mode" {
  description = <<-EOT
    How the Kubernetes API is fronted:
      "managed" (default) - an Octavia LB + floating IP (public, ACL-restricted).
      "vip"     - no LB: reserves a private port on the subnet instead, and
                  relies on modules/talos's Layer2 VIP on the private network.
                  Control plane ports get an allowed_address_pairs entry for the
                  VIP so Neutron's anti-spoofing filter doesn't drop it. The API
                  is then private-only, reachable via the bastion SSH tunnel.
  EOT
  type        = string
  default     = "managed"
  validation {
    condition     = contains(["managed", "vip"], var.k8s_lb_mode)
    error_message = "k8s_lb_mode must be \"managed\" or \"vip\"."
  }
}
