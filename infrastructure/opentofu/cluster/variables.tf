variable "backup_enabled" {
  description = "Whether to backup cluster artifacts to S3. Disable for local testing."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster"
  type        = string
  default     = "openaether"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "cluster_role" {
  description = "Role of this cluster in the CMP: 'management' (hub, runs OpenBao/ESO/Keycloak) or 'workload' (spoke, runs client apps)"
  type        = string
  default     = "workload"
  validation {
    condition     = contains(["management", "workload"], var.cluster_role)
    error_message = "cluster_role must be 'management' or 'workload'."
  }
}

variable "skip_health_check" {
  description = <<-EOT
    Skip the post-bootstrap `talos_cluster_health` data source.

    That data source times out on clusters that are demonstrably healthy (HA
    managements on OVH and Outscale: every node Ready, etcd HEALTH OK on all
    control planes, complete Flux DAG) and returns a bare "context deadline
    exceeded" — see docs/backlog.md.

    Enabling this costs the guardrail that catches a silently failed bootstrap,
    so verify health out of band (`talosctl -n <cp> service etcd`,
    `kubectl get nodes`).
  EOT
  type        = bool
  default     = false
}

variable "talos_bootstrap" {
  description = "Whether to configure Talos via SSH tunnel (Phase 2). Default true — pass -var talos_bootstrap=false for Phase 1 (infra only)."
  type        = bool
  default     = true
}

variable "skip_port_ready_wait" {
  description = <<-EOT
    Skip modules/talos's local-exec wait for 50000/TCP before config-apply.
    That wait is a plain OS-level TCP connect (not part of the "talos"
    provider, so mock_provider doesn't fake it) — under `tofu test` with
    mocked endpoints it would retry forever. Set true only for
    tofu test/CI; keep false for real deploys, where the wait is what makes
    cloud bootstrap deterministic.
  EOT
  type        = bool
  default     = false
}

variable "secrets_prevent_destroy" {
  description = <<-EOT
    Protect module.talos's talos_machine_secrets (the cluster's root-of-trust
    PKI) from destruction. Keep true for real deploys. Set false only for
    tofu test, whose automatic post-run cleanup destroys everything an
    apply-mode run block created — with prevent_destroy = true that cleanup
    errors out (lifecycle arguments can't be variable-driven, so this flows
    into modules/talos as a plain bool instead).
  EOT
  type        = bool
  default     = true
}

variable "auto_tunnels" {
  description = <<-EOT
    EXPERIMENTAL — collapses the two-phase bootstrap into a single `tofu apply`.
    When true (with talos_bootstrap=true), a terraform_data resource opens the
    SSH tunnels itself (scripts/bootstrap/talos-tunnels.sh open-direct) between
    the provider module and modules/talos, using node/bastion IPs that are only
    known once the VMs exist — ordering falls out of the reference graph, no
    manual tunnel step needed. Default false: the documented two-phase flow
    (`task infra` then `task bootstrap-phase2`) remains the supported path.
    Not exercised against a real host yet; validate on a disposable env first.
  EOT
  type        = bool
  default     = false
}

variable "ssh_key_path" {
  description = "SSH private key path used by auto_tunnels=true's terraform_data provisioner (passed to talos-tunnels.sh open-direct --key). Unused when auto_tunnels=false."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "v1.13.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "v1.36.3"
}

variable "node_distribution" {
  description = <<-EOT
    Distribution of nodes per provider. At most one provider may have count > 0 per apply.
    Keys: "scaleway", "ovh", "outscale".

    Common fields (all providers):
      control_planes, workers, region, image_id, image_name

    Scaleway-specific:
      zone            - primary zone (e.g. "fr-par-1")
      zones           - multi-AZ list for HA (e.g. ["fr-par-1", "fr-par-2", "fr-par-3"])
      instance_type   - VM type (e.g. "DEV1-M")

    OVH-specific:
      flavor_name         - OpenStack flavor (e.g. "b3-8")
      network_name        - External network name for floating IPs (default "Ext-Net")
      availability_zones  - OpenStack AZ list (default ["nova"])

    Outscale-specific:
      instance_type      - VM type (e.g. "tinav5.c2r4p1")
      availability_zones - Subregion list (e.g. ["eu-west-2a", "eu-west-2b"])

    Note: local 3-CP Docker testing lives in ../opentofu-local (separate root),
    not here.
  EOT
  type = map(object({
    control_planes     = number
    workers            = number
    region             = optional(string)
    zone               = optional(string)
    zones              = optional(list(string))
    instance_type      = optional(string)
    flavor_name        = optional(string)
    image_id           = optional(string)
    image_name         = optional(string)
    availability_zones = optional(list(string))
    network_name       = optional(string, "Ext-Net")
    bastion_image_id   = optional(string)
    talos_api_port     = optional(number, 50000)
    k8s_api_port       = optional(number, 6443)

    # Cloud-only (scaleway/ovh): "managed" (default, an LB) or "vip" (no LB —
    # a Talos Layer2 VIP on the private network instead). Outscale rejects
    # "vip" (its Net is an L3 SDN, no ARP/broadcast domain). See each
    # provider's k8s_lb_mode variable for the per-cloud mechanism.
    k8s_lb_mode = optional(string, "managed")

    # Proxmox-specific (single host or multi-host cluster). All optional → no
    # impact on the cloud providers. Defaults live in the TYPE (like image_name/
    # network_name): with map(object) an unset field arrives as null and would
    # clobber a merge() default, so type-level defaults are what actually apply.
    # See modules/providers/proxmox for semantics. Host-specific keys with no
    # sane default (talos_image_file_id, gateway_ip, apiserver_vip, host_public_ip)
    # stay null → supplied per-host in the tfvars.
    node_names              = optional(list(string))
    datastore_id            = optional(string, "local-zfs")
    iso_datastore_id        = optional(string, "local")
    talos_image_file_id     = optional(string)
    network_bridge          = optional(string, "vmbr1")
    network_cidr            = optional(string, "10.0.0.0/24")
    gateway_ip              = optional(string)
    apiserver_vip           = optional(string)
    apiserver_vip_interface = optional(string, "eth0")
    cpu_cores               = optional(number, 4)
    memory_mb               = optional(number, 8192)
    root_disk_gb            = optional(number, 20)
    control_plane_ip_offset = optional(number, 10)
    worker_ip_offset        = optional(number, 20)
    nameservers             = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    enable_bastion          = optional(bool, false)
    host_public_ip          = optional(string)
    host_ssh_user           = optional(string, "root")
  }))
  default = {}
}

variable "worker_storage" {
  description = <<-EOT
    Dedicated data storage for worker nodes (the active provider only — one
    provider is active per apply). Decouples the block volumes created/attached
    by the provider module (`disks`) from the encrypted Talos UserVolumeConfig
    documents (`volumes`, mounted at /var/mnt/<name>, LUKS2).

    Default (empty) = no dedicated data disks (workers use the system disk only).

    Examples:
      # Dev — one shared 50GB data disk, two volumes (local-path + Longhorn):
      worker_storage = {
        disks = [{ size_gb = 50 }]
        volumes = [
          { name = "local-path-provisioner", disk_match = "!system_disk", min_size = "20GB", max_size = "25GB" },
          { name = "longhorn",                disk_match = "!system_disk", grow = true },
        ]
      }
      # Prod — one large shared disk: disks = [{ size_gb = 500 }] (same volumes).
      # Prod — dedicated disks: disks = [{ size_gb = 100 }, { size_gb = 400 }]
      #   with disk_match discriminating by size, e.g.
      #   "disk.size < 200000000000u" vs "disk.size > 200000000000u".
  EOT
  type = object({
    disks = optional(list(object({
      size_gb = number
    })), [])
    volumes = optional(list(object({
      name       = string
      disk_match = string
      min_size   = optional(string)
      max_size   = optional(string)
      grow       = optional(bool, false)
    })), [])
  })
  default = { disks = [], volumes = [] }
}

variable "admin_ip" {
  description = "Allowed source IPs/CIDRs for admin access (SSH, K8s API LB ACL)"
  type        = list(string)
}

variable "bastion_ssh_keys" {
  description = "SSH public keys per provider. Key = provider name (scaleway/ovh/outscale), value = list of SSH public keys. Add a key to grant multi-admin access without changing the list structure."
  type        = map(list(string))
  default     = {}
}

# ==============================================================================
# GitOps / Bootstrap
# ==============================================================================

variable "git_repo_url" {
  description = "Git repository URL for the Flux GitRepository source (OpenAether-apps)"
  type        = string
  default     = "https://github.com/dis-bzh/OpenAether-apps.git"
}

variable "flux_namespace" {
  description = "Namespace for Flux installation"
  type        = string
  default     = "flux-system"
}

variable "cilium_manifest" {
  description = "Optional override for Cilium manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "flux_manifest" {
  description = "Optional override for Flux install manifest (rendered from file by default)"
  type        = string
  default     = null
}

variable "flux_bootstrap_manifest" {
  description = "Optional override for Flux bootstrap manifest (rendered from template by default)"
  type        = string
  default     = null
}

# ==============================================================================
# S3 Backup / Disaster Recovery
#
# Every DR artifact lives in TWO object stores: a PRIMARY (the cluster's own
# provider, reached with the apply's AWS_* creds) and a REPLICA (the "-backup"
# bucket — in prod a *different* provider, reached with BACKUP_AWS_* creds, which
# default to the primary creds when unset, e.g. for dev).
#
#   tfstate              -> s3-<cluster>-tfstate-<env>      (+ -backup)
#   kubeconfig/talosconfig -> s3-<cluster>-<role>-<env>     (+ -backup)
#
# Bucket names are DERIVED from this convention (see locals in backup.tf), so you
# only provide the endpoints/regions of the two stores here. tfstate client-side
# encryption is the backend's encryption{} block (AES-GCM); the artifacts are
# client-side encrypted with gpg (AES-256) by scripts/ops/backup-artifacts.sh.
# ==============================================================================

variable "s3_primary_endpoint" {
  description = "S3 endpoint of the PRIMARY store (the cluster's own provider, e.g. https://s3.fr-par.scw.cloud)"
  type        = string
}

variable "s3_primary_region" {
  description = "S3 region of the primary store (e.g. fr-par)"
  type        = string
}

variable "s3_replica_endpoint" {
  description = "S3 endpoint of the REPLICA/backup store. Prod: a different provider (e.g. OVH https://s3.gra.io.cloud.ovh.net); dev: reuse the primary endpoint."
  type        = string
}

variable "s3_replica_region" {
  description = "S3 region of the replica/backup store (prod: e.g. gra)"
  type        = string
}

# ==============================================================================
# Outscale API creds (fed by the Taskfile from the resolved S3/API keys; for
# Outscale the API key == the OOS key). Empty when not deploying Outscale.
# ==============================================================================

variable "outscale_access_key_id" {
  description = "Outscale API access key (Taskfile sets TF_VAR_outscale_access_key_id). Empty = use OSC_* env."
  type        = string
  default     = ""
  sensitive   = true
}

variable "outscale_secret_key_id" {
  description = "Outscale API secret key."
  type        = string
  default     = ""
  sensitive   = true
}
