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

PROJECT="$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")"
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

ensure_bucket "$ARTIFACT_PRIMARY" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK" ||
  echo "  ⚠ ${ARTIFACT_PRIMARY} not ready (will retry at backup time)"

# --- The two shapes, and neither of them silent -------------------------------
#
# A backup store on the SAME provider as the primary survives a deleted bucket.
# It does not survive the provider, which is the only thing it was built for. So
# the configuration must say WHICH of the two shapes was chosen, out loud, before
# anything is created — and if the operator chose the second, it has to be true.
#
# It used to be best-effort with a ⚠ per bucket, in a wall of tofu output: you
# could believe you had a copy on another provider and have nothing at all.
CROSS=no
[ "$REPLICA_EP" != "$PRIMARY_EP" ] && CROSS=yes

REPL_OK=yes
ensure_bucket "${STATE_PRIMARY}-backup"    "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK" "$BACKUP_SK" || REPL_OK=no
ensure_bucket "${ARTIFACT_PRIMARY}-backup" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK" "$BACKUP_SK" || REPL_OK=no

if [ "$CROSS" = no ]; then
  echo "  ~ backup store is the SAME endpoint as the primary (${PRIMARY_EP})"
  echo "    That survives a deleted bucket, not a lost provider. Deliberate for a"
  echo "    single-provider setup; point s3_replica_endpoint elsewhere to change it."
  [ "$REPL_OK" = yes ] || echo "  ⚠ the -backup buckets are not ready"
elif [ "$REPL_OK" = yes ]; then
  echo "  ✓ backup store is a DIFFERENT provider: ${REPLICA_EP}"
else
  echo "✗ s3_replica_endpoint points at another provider (${REPLICA_EP}) and the" >&2
  echo "  -backup buckets could not be created there. Refusing to continue: a copy" >&2
  echo "  you asked for and did not get is worse than no copy at all." >&2
  echo "  That store needs ITS OWN keys — they are namespaced by the CLUSTER's" >&2
  echo "  provider, not the backup's, so set ${PU}_BACKUP_AWS_ACCESS_KEY_ID and" >&2
  echo "  ${PU}_BACKUP_AWS_SECRET_ACCESS_KEY to the credentials of ${REPLICA_EP}." >&2
  echo "  Without them s3_cred falls back to the primary's, which cannot" >&2
  echo "  authenticate against another provider." >&2
  exit 1
fi

echo "✓ buckets ready"
