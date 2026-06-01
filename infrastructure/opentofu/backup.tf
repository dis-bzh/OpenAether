# ==============================================================================
# S3-Compatible Encrypted Backup
# Backs up the operationally-critical, small artifacts (talosconfig, kubeconfig)
# to S3 (Scaleway Object Storage). The full machine configs are intentionally NOT
# backed up here: they embed the large inline manifests (ArgoCD ~1.8MB) and are
# fully derivable from the machine secrets — which already live in the encrypted
# tfstate (the real DR artifact).
#
# Uploaded via the AWS CLI (terraform_data) rather than the aws_s3_object
# resource: the latter hits a "version_id was known, but now unknown" plan-
# consistency bug on S3-compatible (non-AWS) stores. Content is passed as
# base64 env vars (binary-safe) and streamed to `aws s3 cp -`.
#
# Disabled when backup_enabled = false (e.g. local Docker testing).
# ==============================================================================

resource "terraform_data" "backup" {
  count = var.backup_enabled && local.total_control_planes > 0 ? 1 : 0

  # Re-upload only when an artifact actually changes.
  triggers_replace = {
    talosconfig = sha256(module.talos.talosconfig)
    kubeconfig  = sha256(module.talos.kubeconfig_raw)
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      TALOSCONFIG_B64 = base64encode(module.talos.talosconfig)
      KUBECONFIG_B64  = base64encode(module.talos.kubeconfig_raw)
      EP              = var.backup_s3_endpoint
      BUCKET          = var.backup_s3_bucket
      REGION          = var.backup_s3_region
    }

    command = <<-EOT
      set -euo pipefail
      command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required for backups (or set backup_enabled=false)"; exit 1; }
      put() { printf '%s' "$1" | base64 -d | aws s3 cp - "s3://$BUCKET/backups/$2" --endpoint-url "$EP" --region "$REGION" --sse AES256; }
      put "$TALOSCONFIG_B64" talosconfig
      put "$KUBECONFIG_B64"  kubeconfig
      echo "✓ Backed up talosconfig + kubeconfig to s3://$BUCKET/backups/"
    EOT
  }
}
