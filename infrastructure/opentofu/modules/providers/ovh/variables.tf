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

variable "worker_data_volume_type" {
  description = <<-EOT
    Cinder volume type for the worker data disks. MUST NOT be a multiattach type:
    OVH's project-default type is `classic-multiattach` (extra_specs
    multiattach="<is> True"), and Nova then rejects the attachment with
    "Multiattach volumes are only supported starting with compute API version
    2.60" — the provider only negotiates that microversion when multiattach is
    explicitly requested. Observed on a real EU-WEST-PAR apply (2026-07-25).
    Available types: high-speed, high-speed-gen2, *-luks variants (Longhorn
    already does its own LUKS with an OpenBao-held key, so plain is enough).
    ⚠️ `high-speed-gen2` a produit des volumes en `error status` sur un 50 GiB
    en EU-WEST-PAR (2026-07-25) — il a des contraintes de taille/région ;
    `high-speed` fonctionne. Vérifier le type avant de le changer.
  EOT
  type        = string
  default     = "high-speed-gen2"
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
