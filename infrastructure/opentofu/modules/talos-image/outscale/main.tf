# ==============================================================================
# Talos image — Outscale (OMI)
# Outscale has no foreign-image import primitive, so (mirrors Scaleway):
#   Factory (aws-<arch>.raw.zst) -> raw -> OOS (Object Storage)
#     -> outscale_snapshot (import via file_location) -> outscale_image (OMI)
#
# PLATEFORME `aws` (et non `nocloud`) : Outscale est EC2-compatible et expose
# une IMDS EC2. La variante aws de Talos la lit, ce qui apporte DEUX choses
# indispensables à CAPI (CAPOSC livre la machine config en user-data, comme EC2) :
#   1. ingestion du user-data  -> sans elle les VMs CAPI resteraient en
#      maintenance mode, jamais configurées ;
#   2. lecture de public-ipv4  -> l'IP publique (NAT 1:1 côté Outscale, donc
#      invisible de la NIC) devient une NodeAddress et entre dans les SAN du
#      certificat apid ; sans elle, CACPPT échouerait en TLS sur <IP>:50000
#      ("certificate is valid for 10.x, not <IP publique>") et ne pourrait ni
#      bootstrapper etcd ni récupérer le kubeconfig de l'enfant.
# Le flux OpenTofu (two-phase apply) reste inchangé : sans user-data, l'image
# aws démarre elle aussi en maintenance mode et reçoit sa config par l'API Talos.
# ==============================================================================

locals {
  factory_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/aws-${var.arch}.raw.zst"
  raw_path    = "${var.cache_dir}/aws-${var.arch}-${var.talos_version}.raw"
  object_key  = "talos/aws-${var.arch}-${var.talos_version}.raw"
}

# Fetch from Image Factory, decompress, upload the raw disk to OOS for import.
resource "terraform_data" "build_and_upload" {
  triggers_replace = {
    schematic = var.schematic_id
    version   = var.talos_version
    key       = local.object_key
    bucket    = var.bucket_name # re-upload if the staging bucket name changes
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
      echo "▶ Downloading Talos ${var.talos_version} (aws-${var.arch}) from Image Factory..."
      curl -fL --retry 3 "${local.factory_url}" -o "${var.cache_dir}/aws.raw.zst"
      echo "▶ Decompressing (zstd)..."
      zstd -f -d "${var.cache_dir}/aws.raw.zst" -o "${local.raw_path}"
      echo "▶ Uploading to OOS: s3://${var.bucket_name}/${local.object_key}"
      aws s3 cp "${local.raw_path}" "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}"
      rm -f "${var.cache_dir}/aws.raw.zst" "${local.raw_path}"
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
    export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
    # ⚠️ TOLÈRE L'ABSENCE DE L'OBJET. Cette data source est évaluée à CHAQUE
    # plan/refresh, alors que ses valeurs ne servent qu'à la CRÉATION du
    # snapshot. Si elle exigeait l'objet, le `.raw` de staging (~11 Gio, facturé
    # en permanence) ne pourrait jamais être purgé sans casser tout `tofu plan`.
    # D'où la purge automatique après enregistrement de l'OMI, plus bas.
    if aws s3api head-object --bucket "${var.bucket_name}" --key "${local.object_key}" \
         --endpoint-url "${var.s3_endpoint}" --region "${var.region}" >/dev/null 2>&1; then
      url="$(aws s3 presign "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --expires-in 3600)"
      bytes="$(aws s3api head-object --bucket "${var.bucket_name}" --key "${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" --query ContentLength --output text)"
      gib=1073741824
      size=$(( (bytes + gib - 1) / gib * gib ))
    else
      # Objet purgé après import : le snapshot existe déjà, ces valeurs sont
      # ignorées (cf. lifecycle.ignore_changes du snapshot).
      url=""
      size=0
    fi
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

  # ⚠️ L'import de snapshot Outscale est LENT et passe par une file d'attente
  # côté fournisseur : mesuré > 60 min en `in-queue 0%` (2026-07-25), au-delà
  # du timeout par défaut du provider (40 min) → l'apply échoue alors que
  # l'import aboutit ensuite, laissant un snapshot HORS STATE. Si ça se
  # reproduit : NE PAS relancer l'apply tel quel (il recrée un second import
  # d'1 h) ; attendre `completed` puis
  #   tofu import module.outscale[0].outscale_snapshot.talos <snap-id>
  # avant de continuer.
  timeouts {
    create = "120m"
  }

  lifecycle {
    # `file_location` (URL pré-signée, change à chaque run) ET `snapshot_size`
    # proviennent tous deux de l'objet de staging, qui est purgé après import :
    # sans les ignorer, chaque plan verrait une dérive et voudrait recréer un
    # import d'une heure.
    ignore_changes       = [file_location, snapshot_size]
    replace_triggered_by = [terraform_data.build_and_upload]
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
      snapshot_id = outscale_snapshot.talos.snapshot_id
      # ⚠️ DOIT être ≥ à la taille du snapshot, sinon CreateImage échoue
      # ("Volume size must be greater than <snap> size") : l'image aws fait
      # 11 GiB, contre 10 pour l'ancienne nocloud. Marge volontaire.
      volume_size           = 16
      volume_type           = "standard"
      delete_on_vm_deletion = true
    }
  }
}

# Purge du `.raw` de staging, une fois l'OMI enregistrée.
#
# POURQUOI : l'objet fait ~11 Gio et était conservé indéfiniment, un par version
# de Talos — facturé en pure perte. Les artefacts DURABLES sont le snapshot et
# l'OMI ; le `.raw` n'est qu'un intermédiaire d'import, et il est reconstructible
# à l'identique depuis l'Image Factory (le schematic ID est déterministe).
#
# ⚠️ Cette purge n'est possible QUE parce que `data.external.oos_object` tolère
# désormais l'absence de l'objet (cf. plus haut). Supprimer le `.raw` sans ce
# correctif casse tout `tofu plan` du root talos-image.
#
# Déclenché par le même trigger que l'upload : une nouvelle version repasse par
# download → upload → import → OMI → purge.
resource "terraform_data" "purge_staging" {
  triggers_replace = {
    key    = local.object_key
    bucket = var.bucket_name
    image  = outscale_image.talos.image_id
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      echo "▶ Purge du staging : s3://${var.bucket_name}/${local.object_key}"
      aws s3 rm "s3://${var.bucket_name}/${local.object_key}" \
        --endpoint-url "${var.s3_endpoint}" --region "${var.region}" || true
      echo "✓ staging purgé (l'OMI et le snapshot restent les artefacts durables)"
    EOT
  }

  depends_on = [outscale_image.talos]
}
