# ==============================================================================
# Talos image — Outscale
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

variable "image_name" {
  description = "Name of the resulting OMI."
  type        = string
}

variable "bucket_name" {
  description = "OOS bucket used to stage the raw image for the snapshot import."
  type        = string
}

variable "region" {
  description = "Outscale region (e.g. eu-west-2)."
  type        = string
}

variable "s3_endpoint" {
  description = "OOS S3-compatible endpoint (e.g. https://oos.eu-west-2.outscale.com)."
  type        = string
}

variable "cache_dir" {
  description = "Local directory used to stage the downloaded/converted image."
  type        = string
}
