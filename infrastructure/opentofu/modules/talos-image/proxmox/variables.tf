# ==============================================================================
# Talos image — Proxmox (bpg download_file, server-side fetch)
# Downloads the Talos Image Factory nocloud artifact directly onto each PVE
# host's datastore. Unlike the OVH/Scaleway/Outscale builds, there is no local
# fetch/convert step: Proxmox decompresses server-side.
# ==============================================================================

variable "talos_version" {
  description = "Talos version tag (e.g. v1.13.3) — must match an Image Factory release."
  type        = string
}

variable "arch" {
  description = "Image architecture (amd64 or arm64)."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "arch must be amd64 or arm64."
  }
}

variable "schematic_id" {
  description = "Image Factory schematic ID (resolved by the root from schematic.yaml)."
  type        = string
}

variable "node_names" {
  description = "Proxmox node (host) names to download the image onto — one copy per PVE host, since ISO/image datastores are typically per-node local storage. Match modules/providers/proxmox's node_names."
  type        = list(string)
}

variable "iso_datastore_id" {
  description = "Proxmox datastore to store the downloaded image on (must match modules/providers/proxmox's iso_datastore_id)."
  type        = string
  default     = "local"
}
