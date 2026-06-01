variable "cluster_name" {
  description = "Name of the cluster (used to name Docker containers, network, volumes)"
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version — determines the Docker image tag"
  type        = string
}

variable "control_plane_count" {
  description = "Number of control plane containers (1 or 3 for a real quorum)"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker containers"
  type        = number
  default     = 0
}

variable "network_cidr" {
  description = "Docker network CIDR for the cluster (Talos Docker default is 10.5.0.0/24)"
  type        = string
  default     = "10.5.0.0/24"
}

variable "cp_ip_base" {
  description = "Starting host octet for control plane static IPs (e.g. 10 → 10.5.0.10, 10.5.0.11, ...)"
  type        = number
  default     = 10
}

variable "worker_ip_base" {
  description = "Starting host octet for worker static IPs (e.g. 20 → 10.5.0.20, ...)"
  type        = number
  default     = 20
}

variable "talos_api_port_base" {
  description = "Base host port for the Talos API (port N+i → container i's 50000). e.g. 50000 → cp0:50000, cp1:50001"
  type        = number
  default     = 50000
}

variable "k8s_api_port" {
  description = "Host port mapped to control plane 0's Kubernetes API (6443)"
  type        = number
  default     = 6443
}

variable "control_plane_configs" {
  description = "Per-node base64-ready machine configs (plain YAML) to inject via USERDATA. Length must equal control_plane_count."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "worker_configs" {
  description = "Per-node worker machine configs to inject via USERDATA."
  type        = list(string)
  default     = []
  sensitive   = true
}

# Provider contract — accepted but unused for local
variable "admin_ip" {
  description = "Unused in local mode (no firewall/ACL)"
  type        = list(string)
  default     = []
}

variable "bastion_ssh_key" {
  description = "Unused in local mode (no bastion)"
  type        = string
  default     = ""
}
