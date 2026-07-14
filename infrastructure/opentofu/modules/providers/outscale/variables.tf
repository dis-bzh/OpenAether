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
  description = "OMI ID for Talos Linux. Null (default) looks it up by image_name instead — the name the talos-image root publishes under."
  type        = string
  default     = null
}

variable "image_name" {
  description = "OMI name to look up when image_id is null."
  type        = string
  default     = "talos"
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

#tflint-ignore: terraform_unused_declarations -- only referenced by its own
# validation block (rejects "vip"). Exists so cluster/main.tf can pass
# k8s_lb_mode uniformly to all three cloud provider modules; Outscale simply
# never acts on it beyond validating it.
variable "k8s_lb_mode" {
  description = "How the Kubernetes API is fronted. Outscale only supports \"managed\" (a load balancer) — see validation."
  type        = string
  default     = "managed"
  validation {
    # Outscale Net is an L3 SDN (like AWS VPC): no ARP/broadcast domain and NIC
    # anti-spoofing on by default, so a Talos Layer2 VIP has nothing to float
    # on. The k8s LB also sits on the public subnet and returns a DNS name, not
    # an IP, which a Talos VIP can't be either. Unlike Scaleway/OVH (both L2
    # private networks), there's no vip mode here — managed LB only.
    condition     = var.k8s_lb_mode == "managed"
    error_message = "Outscale only supports k8s_lb_mode = \"managed\" — its Net is an L3 SDN with no ARP/broadcast domain for a Talos Layer2 VIP to float on, and the k8s LB is DNS-based on the public subnet, not a floatable IP."
  }
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
