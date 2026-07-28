# ==============================================================================
# S3-Compatible Encrypted Backup / Disaster Recovery
#
# Backs up the operationally-critical access artifacts (talosconfig, kubeconfig)
# to TWO object stores — PRIMARY (the cluster's own provider) and REPLICA (the
# "-backup" store; in prod a *different* provider, different creds). The full
# machine configs are intentionally NOT backed up here: they embed the large
# inline manifests (Flux ~1.8MB) and are fully derivable from the machine
# secrets, which already live in the encrypted tfstate (the real DR artifact).
#
# Encryption (defence in depth):
#   - CLIENT-side: gpg --symmetric AES-256 (authenticated: MDC / OCB on gpg >=2.3),
#     key derived from the SAME passphrase as the tfstate (var.encryption_passphrase),
#     with hardened S2K. This is what protects the data — the storage provider
#     never sees plaintext.
#   - SERVER-side: S3 SSE (AES256) layered on top at upload.
#
# The tfstate itself is already client-encrypted by the backend's encryption{}
# block (AES-GCM + PBKDF2); its replication to the "-backup" store is a separate,
# post-apply step (scripts/backup-state.sh), because the backend only flushes the
# new state after the apply finishes — see backup_targets in outputs.tf.
#
# Done via the AWS CLI (terraform_data + a shell script) rather than the
# aws_s3_object resource: the latter hits a "version_id known -> now unknown"
# plan-consistency bug on S3-compatible (non-AWS) stores.
#
# Disabled when backup_enabled = false (e.g. local Docker testing).
# ==============================================================================

locals {
  # Bucket naming convention: s3-<project>-<provider>-{tfstate|<role>}-<env> (+ -backup).
  # The provider is explicit (not buried in cluster_name) so it's consistent across
  # management and workload clusters; project is cluster_name's first segment.
  backup_project        = split("-", var.cluster_name)[0]
  backup_provider_short = lookup({ scaleway = "scaleway", ovh = "ovh", outscale = "outscale" }, local.active_provider, local.active_provider)
  backup_bucket_prefix  = "s3-${local.backup_project}-${local.backup_provider_short}"

  # Artifacts (kube/talosconfig): the cluster's own provider holds the PRIMARY;
  # a "-backup" store (in prod a different provider) holds the REPLICA.
  artifact_bucket_primary = "${local.backup_bucket_prefix}-${var.cluster_role}-${var.environment}"
  artifact_bucket_replica = "${local.artifact_bucket_primary}-backup"

  # State: the backend (backend.tf, configured via scripts/tf-backend.sh) writes the PRIMARY;
  # scripts/backup-state.sh replicates it to the "-backup" store. Management and
  # workload clusters on the same provider/env share this bucket, distinguished by
  # the per-cluster key. Surfaced via the backup_targets output.
  # Bucket for APPLICATION backups (restic, Longhorn volume backups).
  # Same convention as the others, but it PRE-EXISTS — the operator creates it
  # and seeds its credentials into OpenBao (`secret/backup/s3-primary`). We
  # derive its name here to publish it in the `cluster-identity` ConfigMap that
  # the Longhorn brick consumes: the backup target is a string, it cannot come
  # from a Secret. ⚠️ Must match what is seeded in OpenBao.
  backup_data_bucket = "${local.backup_bucket_prefix}-backups-${var.environment}"

  state_bucket_primary = "${local.backup_bucket_prefix}-tfstate-${var.environment}"
  state_bucket_replica = "${local.state_bucket_primary}-backup"
  state_key            = "${var.cluster_name}.tfstate"
}

resource "terraform_data" "backup" {
  # Only after Phase 2 (talos_bootstrap): before that the kube/talosconfig don't
  # exist yet. backup_enabled=false skips it entirely (local testing).
  count = var.backup_enabled && var.talos_bootstrap && local.total_control_planes > 0 ? 1 : 0

  # Re-upload only when an artifact (or a target) actually changes.
  triggers_replace = {
    talosconfig = sha256(module.talos.talosconfig)
    kubeconfig  = sha256(module.talos.kubeconfig_raw)
    targets     = "${local.artifact_bucket_primary}|${local.artifact_bucket_replica}|${var.s3_primary_endpoint}|${var.s3_replica_endpoint}"
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash"]
    command     = abspath("${path.module}/../../../scripts/ops/backup-artifacts.sh")

    # Secrets (passphrase) and the artifacts go via env (binary-safe base64). The
    # script resolves the S3 creds from PROVIDER (primary + <PU>_BACKUP_AWS_*).
    environment = {
      TALOSCONFIG_B64 = base64encode(module.talos.talosconfig)
      KUBECONFIG_B64  = base64encode(module.talos.kubeconfig_raw)
      PASSPHRASE      = var.encryption_passphrase
      PROVIDER        = local.active_provider
      PRIMARY_BUCKET  = local.artifact_bucket_primary
      PRIMARY_EP      = var.s3_primary_endpoint
      PRIMARY_REGION  = var.s3_primary_region
      REPLICA_BUCKET  = local.artifact_bucket_replica
      REPLICA_EP      = var.s3_replica_endpoint
      REPLICA_REGION  = var.s3_replica_region
    }
  }
}
