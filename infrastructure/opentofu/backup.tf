# ------------------------------------------------------------------------------
# Configuration Generation (for Backup)
# ------------------------------------------------------------------------------

data "talos_machine_configuration" "control_plane_backup" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.formatted_endpoint
  machine_type       = "controlplane"
  machine_secrets    = module.talos.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

data "talos_machine_configuration" "worker_backup" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.formatted_endpoint
  machine_type       = "worker"
  machine_secrets    = module.talos.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

# ------------------------------------------------------------------------------
# S3-Compatible Object Encrypted Backup (SSE-C)
# Uses a generic S3 provider, compatible with Scaleway, Outscale, OVH, MinIO, etc.
# ------------------------------------------------------------------------------



resource "aws_s3_object" "talosconfig" {
  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/talosconfig"
  content                = module.talos.talosconfig
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "kubeconfig" {
  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/kubeconfig"
  content                = talos_cluster_kubeconfig.this.kubeconfig_raw
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "controlplane_yaml" {
  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/controlplane.yaml"
  content                = data.talos_machine_configuration.control_plane_backup.machine_configuration
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "worker_yaml" {
  provider               = aws.backup
  bucket                 = var.backup_s3_bucket
  key                    = "backups/worker.yaml"
  content                = data.talos_machine_configuration.worker_backup.machine_configuration
  server_side_encryption = "AES256"
}
