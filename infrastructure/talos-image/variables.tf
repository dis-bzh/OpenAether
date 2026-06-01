variable "target_provider" {
  description = "Which cloud to build the Talos image for. Only 'scaleway' is implemented today; ovh/outscale are scaffolded next."
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
}

# --- Scaleway ----------------------------------------------------------------

variable "image_bucket" {
  description = "Object Storage bucket used to stage the image for the snapshot import."
  type        = string
  default     = "openaether-talos-images"
}

variable "scaleway_region" {
  description = "Scaleway region."
  type        = string
  default     = "fr-par"
}

variable "scaleway_zones" {
  description = "Scaleway zones to publish the image into. Match the cluster's zones — images are zonal."
  type        = list(string)
  default     = ["fr-par-1", "fr-par-2", "fr-par-3"]
}

variable "s3_endpoint" {
  description = "S3-compatible endpoint for the Object Storage upload."
  type        = string
  default     = "https://s3.fr-par.scw.cloud"
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
