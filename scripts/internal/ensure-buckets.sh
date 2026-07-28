#!/usr/bin/env bash
# OpenAether — ensure the backup object stores exist (idempotent).
#
# Creates the four buckets a cluster needs, names derived from its tfvars (same
# convention as cluster/backup.tf): tfstate and artifacts, each with a -backup
# replica.
#
# Only the STATE PRIMARY must exist before `tofu init` (the S3 backend does not
# create its own bucket) — that one is FATAL. The other three are used later and
# may live on another provider, so they are best-effort and never block a deploy.
#
# Usage: ensure-buckets.sh <path/to/cluster.tfvars>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

TFVARS="${1:?usage: ensure-buckets.sh <cluster.tfvars>}"
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
oa_aws_compat

CLUSTER="$(tfv "$TFVARS" cluster_name)"
ROLE="$(tfv "$TFVARS" cluster_role)"
ENVN="$(tfv "$TFVARS" environment)"
PRIMARY_EP="$(tfv "$TFVARS" s3_primary_endpoint)"
PRIMARY_REGION="$(tfv "$TFVARS" s3_primary_region)"
REPLICA_EP="$(tfv "$TFVARS" s3_replica_endpoint)"
REPLICA_REGION="$(tfv "$TFVARS" s3_replica_region)"
PROVIDER="$(tfv_provider "$TFVARS")"
PU="$(provider_pu "$PROVIDER")" || { echo "✗ could not detect provider from node_distribution in $TFVARS"; exit 1; }

[ -n "$CLUSTER" ] && [ -n "$ROLE" ] && [ -n "$ENVN" ] || {
  echo "✗ could not read cluster_name/cluster_role/environment from $TFVARS"; exit 1; }
[ -n "$PRIMARY_EP" ] && [ -n "$REPLICA_EP" ] || {
  echo "✗ could not read s3_primary_endpoint/s3_replica_endpoint from $TFVARS"; exit 1; }

PROJECT="${CLUSTER%%-*}"
PRIMARY_AK="$(s3_cred "$PROVIDER" primary ak)"
PRIMARY_SK="$(s3_cred "$PROVIDER" primary sk)"
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak)"
BACKUP_SK="$(s3_cred "$PROVIDER" backup sk)"
[ -n "$PRIMARY_AK" ] || {
  echo "✗ no S3 creds for '${PROVIDER}': export ${PU}_AWS_ACCESS_KEY_ID + ${PU}_AWS_SECRET_ACCESS_KEY"; exit 1; }

STATE_PRIMARY="$(oa_state_bucket "$PROJECT" "$PROVIDER" "$ENVN")"
ARTIFACT_PRIMARY="$(oa_artifact_bucket "$PROJECT" "$PROVIDER" "$ROLE" "$ENVN")"

ensure_bucket() { # name  endpoint  region  access_key  secret_key
  if AWS_ACCESS_KEY_ID="$4" AWS_SECRET_ACCESS_KEY="$5" \
       aws s3api head-bucket --bucket "$1" --endpoint-url "$2" --region "$3" >/dev/null 2>&1; then
    echo "  ✓ $1 (exists)"
  else
    AWS_ACCESS_KEY_ID="$4" AWS_SECRET_ACCESS_KEY="$5" \
      aws s3 mb "s3://$1" --endpoint-url "$2" --region "$3" >/dev/null \
      && echo "  + $1 (created)"
  fi
}

echo "▶ Ensuring buckets for ${PROJECT} (${PU}/${ROLE}/${ENVN})"

# State PRIMARY — REQUIRED before `tofu init`. Fatal under set -e.
ensure_bucket "$STATE_PRIMARY" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK"

# The rest are needed only later and may live on another provider — best-effort.
ensure_bucket "$ARTIFACT_PRIMARY"          "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK" || echo "  ⚠ ${ARTIFACT_PRIMARY} not ready (will retry at backup time)"
ensure_bucket "${STATE_PRIMARY}-backup"    "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK"  "$BACKUP_SK"  || echo "  ⚠ ${STATE_PRIMARY}-backup not ready (set ${PU}_BACKUP_AWS_* for a cross-provider replica)"
ensure_bucket "${ARTIFACT_PRIMARY}-backup" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK"  "$BACKUP_SK"  || echo "  ⚠ ${ARTIFACT_PRIMARY}-backup not ready (set ${PU}_BACKUP_AWS_* for a cross-provider replica)"

echo "✓ State primary bucket ready (backups best-effort)"
