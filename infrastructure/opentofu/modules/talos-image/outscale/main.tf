# ==============================================================================
# Talos image — Outscale (OMI)
# Outscale has no foreign-image import primitive, so (mirrors Scaleway):
#   Factory (nocloud-<arch>.raw.zst) -> raw -> OOS (Object Storage)
#     -> outscale_snapshot (import via file_location) -> outscale_image (OMI)
# Outscale is EC2-compatible; the generic `nocloud` Talos image boots into
# maintenance mode and the cluster's two-phase apply pushes the config over the
# SSH tunnel (no cloud-metadata dependency needed at boot).
# ==============================================================================

locals {
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/nocloud-${var.arch}.raw.zst"
  raw_path    = "${var.cache_dir}/nocloud-${var.arch}-${var.talos_version}.raw"
  object_key  = "talos/nocloud-${var.arch}-${var.talos_version}.raw"
}

# Fetch from Image Factory, decompress, upload the raw disk to OOS for import.
resource "terraform_data" "build_and_upload" {
  triggers_replace = {
    schematic = var.schematic_id
    version   = var.talos_version
    key       = local.object_key
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # S3-compatible stores (OOS/OVH) reject the AWS CLI v2.23+ default trailing
      # checksum — only add checksums when the operation actually requires them.
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      for bin in curl zstd aws; do
        command -v "$bin" >/dev/null 2>&1 || { echo "✗ required tool not found: $bin — run 'task setup'"; exit 1; }
      done
      mkdir -p "${var.cache_dir}"
      echo "▶ Downloading Talos ${var.talos_version} (nocloud-${var.arch}) from Image Factory..."
      curl -fL --retry 3 "${local.factory_url}" -o "${var.cache_dir}/nocloud.raw.zst"
      echo "▶ Decompressing (zstd)..."
      zstd -f -d "${var.cache_dir}/nocloud.raw.zst" -o "${local.raw_path}"
      echo "▶ Uploading to OOS: s3://${var.bucket_name}/${local.object_key}"
      aws s3 cp "${local.raw_path}" "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}"
      rm -f "${var.cache_dir}/nocloud.raw.zst" "${local.raw_path}"
      echo "✓ Raw image staged for snapshot import."
    EOT
  }
}

# Outscale's ImportSnapshot needs (a) a PRE-SIGNED URL to read the OOS object
# (a plain URL to a private object is denied with 401), and (b) the snapshot size
# in BYTES, >= the file size. Compute both after the upload: presign + head-object
# (ContentLength rounded up to the next GiB). The presigned URL changes every run
# (so file_location is ignored after create); the size is deterministic.
data "external" "oos_object" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    url="$(aws s3 presign "s3://${var.bucket_name}/${local.object_key}" \
      --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --expires-in 3600)"
    bytes="$(aws s3api head-object --bucket "${var.bucket_name}" --key "${local.object_key}" \
      --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --query ContentLength --output text)"
    gib=1073741824
    size=$(( (bytes + gib - 1) / gib * gib ))
    printf '{"url":"%s","size":"%s"}' "$url" "$size"
  EOT
  ]

  depends_on = [terraform_data.build_and_upload]
}

# Import the raw disk from OOS as a snapshot (SnapshotSize is in BYTES).
resource "outscale_snapshot" "talos" {
  file_location = data.external.oos_object.result.url
  snapshot_size = tonumber(data.external.oos_object.result.size)
  description   = "Talos ${var.talos_version} (${var.arch}) — imported for OMI registration"

  lifecycle {
    ignore_changes = [file_location]
  }

  depends_on = [terraform_data.build_and_upload]
}

# Register a bootable OMI from the imported snapshot. The cluster references it by
# ID (set image_id in the cluster envs/*.tfvars).
resource "outscale_image" "talos" {
  image_name       = var.image_name
  architecture     = var.arch == "arm64" ? "arm64" : "x86_64"
  root_device_name = "/dev/sda1"

  block_device_mappings {
    device_name = "/dev/sda1"
    bsu {
      snapshot_id           = outscale_snapshot.talos.snapshot_id
      volume_size           = 10
      volume_type           = "standard"
      delete_on_vm_deletion = true
    }
  }
}
