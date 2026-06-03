# ==============================================================================
# OpenStack (OVH) has Glance, which uploads a local image file directly, so —
# unlike Scaleway — no Object Storage staging is needed:
#   Factory (openstack-<arch>.raw.zst) -> qcow2 -> Glance image
# The fetch/convert step is imperative (local-exec); the Glance image is then
# declarative and tracked in state. The cluster references the image by ID.
# ==============================================================================

locals {
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/openstack-${var.arch}.raw.zst"
  qcow2_path  = "${var.cache_dir}/openstack-${var.arch}-${var.talos_version}.qcow2"
}

# Fetch from Image Factory, decompress (zstd), convert to QCOW2. Re-runs only when
# the schematic/version changes. The QCOW2 is kept in the cache dir because Glance
# reads it by path; don't wipe .talos-image-cache between plan and apply.
resource "terraform_data" "build" {
  triggers_replace = {
    schematic = var.schematic_id
    version   = var.talos_version
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      for bin in curl zstd qemu-img; do
        command -v "$bin" >/dev/null 2>&1 || {
          echo "✗ required tool not found: $bin — run 'task setup'"; exit 1; }
      done
      mkdir -p "${var.cache_dir}"
      echo "▶ Downloading Talos ${var.talos_version} (openstack-${var.arch}) from Image Factory..."
      curl -fL --retry 3 "${local.factory_url}" -o "${var.cache_dir}/openstack.raw.zst"
      echo "▶ Decompressing (zstd) + converting to QCOW2 (qemu-img)..."
      zstd -f -d "${var.cache_dir}/openstack.raw.zst" -o "${var.cache_dir}/openstack.raw"
      qemu-img convert -f raw -O qcow2 "${var.cache_dir}/openstack.raw" "${local.qcow2_path}"
      rm -f "${var.cache_dir}/openstack.raw.zst" "${var.cache_dir}/openstack.raw"
      echo "✓ QCOW2 ready for Glance upload: ${local.qcow2_path}"
    EOT
  }
}

# Upload to Glance as a private image (region-wide).
resource "openstack_images_image_v2" "talos" {
  name             = var.image_name
  local_file_path  = local.qcow2_path
  disk_format      = "qcow2"
  container_format = "bare"
  visibility       = "private"

  properties = {
    architecture = var.arch == "arm64" ? "aarch64" : "x86_64"
    os_distro    = "talos"
  }

  tags = ["talos", var.talos_version, "managed-by-opentofu"]

  depends_on = [terraform_data.build]
}
