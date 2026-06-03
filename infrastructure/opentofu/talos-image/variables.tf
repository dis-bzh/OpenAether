variable "target_provider" {
  description = "Which cloud to build the Talos image for: scaleway, ovh, or outscale."
  type        = string
  default     = "scaleway"

  validation {
    condition     = contains(["scaleway", "ovh", "outscale"], var.target_provider)
    error_message = "target_provider must be one of: scaleway, ovh, outscale."
  }
}

variable "talos_version" {
  description = "Talos version tag (must exist on Image Factory). Keep in sync with the cluster envs/*.tfvars."
  type        = string
  default     = "v1.13.3"
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

# --- Scaleway-specific (unused by the OVH glance / Outscale builds) -----------

variable "staging_bucket" {
  description = "Object Storage bucket used to stage the image for the snapshot import (Scaleway/Outscale upload path)."
  type        = string
  default     = "s3-openaether-scw-talos-staging"
}

variable "region" {
  description = "Region for the image build (Scaleway bucket + zonal images)."
  type        = string
  default     = "fr-par"
}

variable "zones" {
  description = "Scaleway zones to publish the image into (images are zonal). Unused by OVH/Outscale."
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "s3_endpoint" {
  description = "S3-compatible endpoint for the Object Storage upload (Scaleway/Outscale)."
  type        = string
  default     = "https://s3.fr-par.scw.cloud"
}

# --- Outscale API creds (fed by the orchestrator; same AK/SK as OOS) ----------

variable "outscale_access_key_id" {
  description = "Outscale API access key (the orchestrator sets it from the resolved OOS keys). Empty = use OSC_* env."
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

# --- State encryption (mirrors the cluster root) -----------------------------

variable "encryption_passphrase" {
  type      = string
  sensitive = true

  validation {
    condition     = length(var.encryption_passphrase) >= 32
    error_message = "encryption_passphrase must be at least 32 characters long."
  }
}
