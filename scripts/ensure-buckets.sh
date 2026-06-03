#!/usr/bin/env bash
# ==============================================================================
# OpenAether — ensure the backup object stores exist (idempotent)
#
# Creates (if missing) the buckets a cluster needs. Names are DERIVED from the
# cluster's tfvars (same convention as backup.tf), keeping this DRY:
#
#   state     -> s3-<project>-<provider>-tfstate-<env>   (+ -backup)
#   artifacts -> s3-<project>-<provider>-<role>-<env>    (+ -backup)
#
# where <project> = cluster_name's first segment, <provider> = scaleway|ovh|outscale
# (detected from node_distribution).
#
# Only the STATE PRIMARY must exist before `tofu init` (the S3 backend won't
# create its own bucket) — that one is FATAL. The three others (state replica +
# both artifact buckets) are only used later (post-apply replication / Phase-2
# gpg backup) and may live on another provider, so they are BEST-EFFORT here and
# never block the deploy.
#
# Creds are resolved via variable indirection (same logic as talos-image.sh):
#   Primary : ${PU}_AWS_ACCESS_KEY_ID (+ _ACCESS_KEY form) → AWS_ACCESS_KEY_ID
#   Backup  : ${PU}_BACKUP_AWS_ACCESS_KEY_ID → BACKUP_AWS_ACCESS_KEY_ID → primary
# where PU = SCW | OVH | OUTSCALE.  Both _ID and non-_ID forms accepted.
#
# Usage: ./scripts/ensure-buckets.sh <path/to/cluster.tfvars>
# ==============================================================================
set -euo pipefail

TFVARS="${1:?usage: ensure-buckets.sh <cluster.tfvars>}"
[ -f "$TFVARS" ] || { echo "✗ tfvars not found: $TFVARS"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }

# S3-compatible stores reject the AWS CLI v2.23+ default trailing checksum.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

# Pull a top-level string assignment (key = "value"), ignoring inline comments.
val() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//'
}

CLUSTER="$(val cluster_name)"
ROLE="$(val cluster_role)"
ENVN="$(val environment)"
PRIMARY_EP="$(val s3_primary_endpoint)"
PRIMARY_REGION="$(val s3_primary_region)"
REPLICA_EP="$(val s3_replica_endpoint)"
REPLICA_REGION="$(val s3_replica_region)"

# Active provider — also derive PU (uppercase prefix for cred lookups, mirrors
# talos-image.sh: scaleway→SCW, ovh→OVH, outscale→OUTSCALE).
PROVIDER_LONG="$(grep -E '^[[:space:]]*(scaleway|ovh|outscale)[[:space:]]*=' "$TFVARS" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*([a-z]+).*/\1/')"
case "$PROVIDER_LONG" in
  scaleway) PROVIDER=scaleway PU=SCW ;;
  ovh)      PROVIDER=ovh      PU=OVH ;;
  outscale) PROVIDER=outscale PU=OUTSCALE ;;
  *) echo "✗ could not detect provider from node_distribution in $TFVARS"; exit 1 ;;
esac

[ -n "$CLUSTER" ] && [ -n "$ROLE" ] && [ -n "$ENVN" ] || {
  echo "✗ could not read cluster_name/cluster_role/environment from $TFVARS"; exit 1; }
[ -n "$PRIMARY_EP" ] && [ -n "$REPLICA_EP" ] || {
  echo "✗ could not read s3_primary_endpoint/s3_replica_endpoint from $TFVARS"; exit 1; }

# Resolve primary S3 creds via variable indirection.
# Try ${PU}_AWS_ACCESS_KEY_ID → ${PU}_AWS_ACCESS_KEY → generic AWS_* → native API keys.
v_akid="${PU}_AWS_ACCESS_KEY_ID"; v_ak="${PU}_AWS_ACCESS_KEY"
v_skid="${PU}_AWS_SECRET_ACCESS_KEY"; v_sk="${PU}_AWS_SECRET_KEY"
PRIMARY_AK="${!v_akid:-${!v_ak:-${AWS_ACCESS_KEY_ID:-}}}"
PRIMARY_SK="${!v_skid:-${!v_sk:-${AWS_SECRET_ACCESS_KEY:-}}}"
case "$PROVIDER" in
  scaleway) PRIMARY_AK="${PRIMARY_AK:-${SCW_ACCESS_KEY:-}}"; PRIMARY_SK="${PRIMARY_SK:-${SCW_SECRET_KEY:-}}" ;;
  outscale) PRIMARY_AK="${PRIMARY_AK:-${OSC_ACCESS_KEY:-}}"; PRIMARY_SK="${PRIMARY_SK:-${OSC_SECRET_KEY:-}}" ;;
esac
[ -n "$PRIMARY_AK" ] || {
  echo "✗ no S3 creds for '${PROVIDER}': export ${PU}_AWS_ACCESS_KEY_ID + ${PU}_AWS_SECRET_ACCESS_KEY"
  exit 1
}

# Backup creds: ${PU}_BACKUP_AWS_* → generic BACKUP_AWS_* → primary creds (dev: same provider).
bv_akid="${PU}_BACKUP_AWS_ACCESS_KEY_ID"; bv_ak="${PU}_BACKUP_AWS_ACCESS_KEY"
bv_skid="${PU}_BACKUP_AWS_SECRET_ACCESS_KEY"; bv_sk="${PU}_BACKUP_AWS_SECRET_KEY"
BACKUP_AK="${!bv_akid:-${!bv_ak:-${BACKUP_AWS_ACCESS_KEY_ID:-$PRIMARY_AK}}}"
BACKUP_SK="${!bv_skid:-${!bv_sk:-${BACKUP_AWS_SECRET_ACCESS_KEY:-$PRIMARY_SK}}}"

PROJECT="${CLUSTER%%-*}"
PREFIX="s3-${PROJECT}-${PROVIDER}"
STATE_PRIMARY="${PREFIX}-tfstate-${ENVN}"
ARTIFACT_PRIMARY="${PREFIX}-${ROLE}-${ENVN}"

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
