variable "cluster_name" {
  type    = string
  default = "openaether-local"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "talos_version" {
  type    = string
  default = "v1.13.3"
}

variable "kubernetes_version" {
  type    = string
  default = "v1.35.3"
}

variable "talos_bootstrap" {
  description = "Phase 2: bootstrap the cluster (containers + etcd + kubeconfig). Set to true for a full cluster; false generates config only."
  type        = bool
  default     = false
}

variable "control_plane_count" {
  description = "Number of control plane containers (3 for a real etcd quorum, 1 for a quick smoke test)"
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 or 3 for a valid local quorum."
  }
}

variable "worker_count" {
  description = "Number of dedicated worker containers. 2 gives schedulable, untainted nodes for HA/scheduling tests; 0 falls back to scheduling on the (untainted) control planes."
  type        = number
  default     = 3
  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 3
    error_message = "worker_count must be between 0 and 3 for local testing."
  }
}

# ⚠️ Base for the Talos API HOST ports: cp_i → base+i, worker_i → base+10+i.
#
# DO NOT raise this above 49152 on Windows/WSL2. That is where the TCP dynamic
# range starts, and Hyper-V RESERVES blocks of 100 ports inside it — Docker
# Desktop then fails to publish the port with a message that does not say why:
#   docker: Error response from daemon: ports are not available: exposing port
#   TCP 127.0.0.1:51000 -> 127.0.0.1:0: /forwards/expose returned unexpected
#   status: 500
# and the cluster dies further along on "Talos API not ready after 90s".
# The previous value (51000) fell inside the 50924-51023 reservation observed on
# 2026-07-28. Those blocks MOVE across reboots: a value below 49152 sits outside
# the dynamic range and is therefore stable.
#
# Inspect a machine with: netsh.exe int ipv4 show excludedportrange protocol=tcp
variable "talos_api_port_base" {
  description = "Base host port for the Talos API (cp_i → base+i, worker_i → base+10+i). Keep below 49152 on Windows/WSL2: the dynamic range above is subject to Hyper-V reservations."
  type        = number
  default     = 41000
  validation {
    condition     = var.talos_api_port_base >= 1024 && var.talos_api_port_base <= 49100
    error_message = "talos_api_port_base must be between 1024 and 49100 (above 49152 collides with the Windows dynamic port range reserved by Hyper-V)."
  }
}

# Accept cilium manifest override (for local simplified variant)
variable "cilium_manifest" {
  description = "Cilium manifest content. Set via TF_VAR_cilium_manifest from cilium-local.yaml."
  type        = string
  default     = null
}
