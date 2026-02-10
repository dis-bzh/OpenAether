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

locals {
  # SSE-C requires a 32-byte key. We use the first 32 characters of
  # the passphrase (validated to be >= 32 chars in backend.tf).
  sse_customer_key = substr(var.encryption_passphrase, 0, 32)
}

resource "aws_s3_object" "talosconfig" {
  provider             = aws.backup
  bucket               = var.backup_s3_bucket
  key                  = "backups/talosconfig"
  content              = module.talos.talosconfig
  sse_customer_algorithm = "AES256"
  sse_customer_key       = local.sse_customer_key
}

resource "aws_s3_object" "kubeconfig" {
  provider             = aws.backup
  bucket               = var.backup_s3_bucket
  key                  = "backups/kubeconfig"
  content              = talos_cluster_kubeconfig.this.kubeconfig_raw
  sse_customer_algorithm = "AES256"
  sse_customer_key       = local.sse_customer_key
}

resource "aws_s3_object" "controlplane_yaml" {
  provider             = aws.backup
  bucket               = var.backup_s3_bucket
  key                  = "backups/controlplane.yaml"
  content              = data.talos_machine_configuration.control_plane_backup.machine_configuration
  sse_customer_algorithm = "AES256"
  sse_customer_key       = local.sse_customer_key
}

resource "aws_s3_object" "worker_yaml" {
  provider             = aws.backup
  bucket               = var.backup_s3_bucket
  key                  = "backups/worker.yaml"
  content              = data.talos_machine_configuration.worker_backup.machine_configuration
  sse_customer_algorithm = "AES256"
  sse_customer_key       = local.sse_customer_key
}
