# ==============================================================================
# S3-Compatible Encrypted Backup
# Backs up critical cluster artifacts to S3 (Scaleway Object Storage).
# Disabled when backup_enabled=false (e.g., local Docker testing).
# ==============================================================================

resource "aws_s3_object" "talosconfig" {
  count = var.backup_enabled ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/talosconfig"
  content                = module.talos.talosconfig
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "kubeconfig" {
  count = var.backup_enabled && length(local.control_plane_ips) > 0 ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/kubeconfig"
  content                = module.talos.kubeconfig_raw
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "controlplane_yaml" {
  count = var.backup_enabled && length(local.control_plane_ips) > 0 ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/controlplane.yaml"
  content                = module.talos.control_plane_config
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "worker_yaml" {
  count = var.backup_enabled && length(local.worker_ips) > 0 ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/worker.yaml"
  content                = module.talos.worker_config
  server_side_encryption = "AES256"
}
