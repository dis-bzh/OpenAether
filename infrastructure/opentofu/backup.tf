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
# Scaleway Object Encrypted Backup (SSE-C)
# Key is derived from a 32-char slice of the encryption passphrase
# ------------------------------------------------------------------------------

locals {
  # SSE-C in Scaleway provider has a validation bug enforcing exactly 32 chars.
  # We use the first 32 characters of your secure passphrase to satisfy this.
  sse_customer_key = substr(var.encryption_passphrase, 0, 32)
}

resource "scaleway_object" "talosconfig" {
  bucket           = "s3-openaether-tfstate"
  key              = "backups/talosconfig"
  content          = module.talos.talosconfig
  sse_customer_key = local.sse_customer_key
  visibility       = "private"
}

resource "scaleway_object" "kubeconfig" {
  bucket           = "s3-openaether-tfstate"
  key              = "backups/kubeconfig"
  content          = talos_cluster_kubeconfig.this.kubeconfig_raw
  sse_customer_key = local.sse_customer_key
  visibility       = "private"
}

resource "scaleway_object" "controlplane_yaml" {
  bucket           = "s3-openaether-tfstate"
  key              = "backups/controlplane.yaml"
  content          = data.talos_machine_configuration.control_plane_backup.machine_configuration
  sse_customer_key = local.sse_customer_key
  visibility       = "private"
}

resource "scaleway_object" "worker_yaml" {
  bucket           = "s3-openaether-tfstate"
  key              = "backups/worker.yaml"
  content          = data.talos_machine_configuration.worker_backup.machine_configuration
  sse_customer_key = local.sse_customer_key
  visibility       = "private"
}
