# ==============================================================================
# S3-Compatible Encrypted Backup
# Uses a generic S3 provider (Scaleway, Outscale, OVH, MinIO, etc.)
# ==============================================================================

resource "aws_s3_object" "talosconfig" {
  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/talosconfig"
  content                = module.talos.talosconfig
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "kubeconfig" {
  count = var.admin_lb_enabled ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/kubeconfig"
  content                = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  server_side_encryption = "AES256"

  depends_on = [talos_cluster_kubeconfig.this]
}

resource "aws_s3_object" "controlplane_yaml" {
  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/controlplane.yaml"
  content                = module.scw[0].control_plane_machine_config
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "worker_yaml" {
  count = (local.scw_dist.control_planes + local.scw_dist.workers) > 0 ? 1 : 0

  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/worker.yaml"
  content                = module.scw[0].worker_machine_config
  server_side_encryption = "AES256"
}
