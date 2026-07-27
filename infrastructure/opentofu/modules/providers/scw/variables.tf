variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "region" {
  description = "Scaleway region (e.g. fr-par)"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Scaleway primary zone (e.g. fr-par-1)"
  type        = string
  default     = "fr-par-1"
}

variable "additional_zones" {
  description = "Zones for multi-AZ distribution of nodes"
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "project_id" {
  description = "Scaleway Project ID (null = provider default)"
  type        = string
  default     = null
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

variable "instance_type" {
  description = "Instance type for cluster nodes"
  type        = string
  default     = "DEV1-S"
}

variable "root_volume_type" {
  description = "Root volume type. 'sbs_volume' for block-storage instances (PRO2/POP2, recommended); 'l_ssd' for local-SSD instances (DEV1/GP1)."
  type        = string
  default     = "sbs_volume"
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data disks per worker. Each `disks` entry creates one SBS block
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

variable "image_id" {
  description = "Talos image ID (zonal, overrides image_name)"
  type        = string
  default     = null
}

variable "image_name" {
  description = "Talos image name (looked up across zones)"
  type        = string
  default     = "talos"
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
  default     = "ubuntu_jammy"
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host (jump box; the default is a minimal, low-cost type)."
  type        = string
  default     = "DEV1-S"
}

variable "k8s_lb_mode" {
  description = <<-EOT
    How the Kubernetes API is fronted:
      "managed" (default) - a Scaleway LB (public IP, ACL-restricted).
      "vip"     - EXPERIMENTAL. No LB: reserves a private IPAM address instead,
                  and relies on modules/talos's Layer2 VIP (ARP-announced by
                  whichever control plane holds it) on the private network.
                  The API is then private-only, reachable via the bastion SSH
                  tunnel — no public IP for 6443. Scaleway's private network
                  anti-spoofing behavior with a floating ARP-announced address
                  is undocumented; validate before relying on this in prod.
  EOT
  type        = string
  default     = "managed"
  validation {
    condition     = contains(["managed", "vip"], var.k8s_lb_mode)
    error_message = "k8s_lb_mode must be \"managed\" or \"vip\"."
  }
}

# ==============================================================================
# NodePorts du Gateway — CONTRAT INTER-DÉPÔTS
#
# Le LB applicatif public est créé en PHASE 1, avant que le cluster n'existe :
# il ne peut donc pas découvrir un nodePort alloué dynamiquement par Kubernetes
# (plage aléatoire 30000-32767). Les ports sont donc FIGÉS des deux côtés.
#
# ⚠️ Ces valeurs DOIVENT correspondre à
# OpenAether-apps/apps/base/services-gateway/service-nodeport.yaml.
# Un écart = LB public qui pointe dans le vide, sans erreur nulle part — c'est
# exactement la panne d'origine (le LB ciblait worker:80/443 alors que le
# Gateway Istio n'y écoutait pas).
# ==============================================================================
variable "app_lb_node_ports" {
  description = "NodePorts figés du Gateway, cibles du LB applicatif public. Doit correspondre au Service openaether-gateway-nodeport côté apps."
  type = object({
    http  = number
    https = number
  })
  default = {
    http  = 30080
    https = 30443
  }
}
