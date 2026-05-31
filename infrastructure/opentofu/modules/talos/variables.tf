variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL (https://<lb_ip>:6443)"
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version (e.g. v1.12.0)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (e.g. v1.34.1)"
  type        = string
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

variable "control_plane_ips" {
  description = "Node identity IPs of control plane nodes (used as the Talos `node` and in certSANs/etcd). Cloud: private IPs. Local Docker: container IPs (e.g. 10.5.0.10)."
  type        = list(string)
}

variable "worker_ips" {
  description = "Node identity IPs of worker nodes"
  type        = list(string)
}

variable "control_plane_endpoints" {
  description = <<-EOT
    Addresses (host or host:port) the Talos provider connects to for each control
    plane node. Defaults to control_plane_ips when empty (cloud: nodes reachable
    directly via VPC/tunnel). For local Docker, set to port-mapped addresses
    (e.g. ["127.0.0.1:50000", "127.0.0.1:50001"]) since container IPs aren't
    routable from the host.
  EOT
  type        = list(string)
  default     = []
}

variable "worker_endpoints" {
  description = "Addresses the Talos provider connects to for each worker. Defaults to worker_ips when empty."
  type        = list(string)
  default     = []
}

variable "health_check_timeout" {
  description = "Max time to wait for the cluster to report healthy after bootstrap (Cilium/CoreDNS image pulls on a fresh multi-CP cluster can take several minutes)."
  type        = string
  default     = "15m"
}

variable "skip_health_check" {
  description = <<-EOT
    Skip the talos_cluster_health data source entirely. The Talos provider's
    health data source has connectivity assumptions that don't hold behind
    WSL2/Docker port mappings (it can stall). For local testing set this true
    and verify health out-of-band via `talosctl health`; keep false for cloud.
  EOT
  type        = bool
  default     = false
}

variable "skip_kubernetes_health_checks" {
  description = <<-EOT
    Skip the Kubernetes-level checks in the Talos health data source (etcd/Talos
    checks still run). Set true for local Docker where the K8s API at the cluster
    endpoint isn't reachable from the host (it's verified separately via kubectl
    over the port-mapped endpoint). Keep false for cloud.
  EOT
  type        = bool
  default     = false
}

variable "config_delivery" {
  description = <<-EOT
    How machine configuration reaches nodes:
      'apply'    - gRPC maintenance-mode apply via talos_machine_configuration_apply
                   (cloud VMs boot in maintenance, then config is applied).
      'userdata' - config is injected at container/VM creation (USERDATA env var).
                   Required for Docker/container platforms — maintenance-mode apply
                   reboot-loops in containers (see Talos Docker platform docs).
                   The provider module reads the *_machine_configs outputs and
                   injects them; this module skips the apply resources.
  EOT
  type        = string
  default     = "apply"
  validation {
    condition     = contains(["apply", "userdata"], var.config_delivery)
    error_message = "config_delivery must be 'apply' or 'userdata'."
  }
}

variable "k8s_lb_ip" {
  description = "IP of the Kubernetes API load balancer (for certSANs)"
  type        = string
}

# ==============================================================================
# Bootstrap Manifests (injected via Talos inlineManifests)
# ==============================================================================

variable "bootstrap_manifests_enabled" {
  description = "Whether to inject bootstrap manifests (Cilium, ArgoCD) via inlineManifests. Set to true for initial bootstrap, false for upgrades/DRP where ArgoCD is already running."
  type        = bool
  default     = true
}

variable "cilium_manifest" {
  description = "Cilium CNI manifest YAML content (from bootstrap-manifests/cilium.yaml). Always injected when bootstrap_manifests_enabled=true (CNI is required for networking)."
  type        = string
}

variable "argocd_manifest" {
  description = "ArgoCD install manifest YAML content (from bootstrap-manifests/argocd-install.yaml)"
  type        = string
  default     = ""
}

variable "root_app_manifest" {
  description = "ArgoCD root Application manifest YAML content (rendered from template)"
  type        = string
  default     = ""
}

variable "container_mode" {
  description = <<-EOT
    Run Talos in container mode (Docker/local testing).
    When true, the machine.install block is omitted from the config patch —
    Talos skips disk installation and runs entirely in memory.
    Required for Docker-based local testing where no block device exists.
  EOT
  type        = bool
  default     = false
}
