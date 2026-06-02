#!/usr/bin/env bash
# ==============================================================================
# OpenAether — replicate the (already client-encrypted) tfstate to the backup store
#
# The S3 backend object is ALREADY ciphertext (OpenTofu encryption{} block,
# AES-GCM + PBKDF2). This copies it from the PRIMARY bucket to the "-backup" one —
# in prod a DIFFERENT provider (BACKUP_AWS_* creds) — layering S3 SSE on top.
#
# Run AFTER each apply: the S3 backend only flushes the new state when the apply
# process exits, so an in-apply copy would capture the *previous* state. The
# bucket/endpoint/key values come from the `backup_targets` tofu output.
#
# Usage:
#   ./scripts/backup-state.sh [tofu_dir]     # default: infrastructure/opentofu
#
# Env:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY                 primary store creds
#   BACKUP_AWS_ACCESS_KEY_ID / BACKUP_AWS_SECRET_ACCESS_KEY   replica store creds
#                                                            (default: primary creds)
# ==============================================================================
set -euo pipefail

TOFU_DIR="${1:-infrastructure/opentofu}"

command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "✗ jq required"; exit 1; }

cd "$TOFU_DIR"

T="$(tofu output -json backup_targets 2>/dev/null || echo 'null')"
[ "$T" != "null" ] && [ -n "$T" ] || {
  echo "⚠ no backup_targets output — apply the infra first (or backup_enabled=false). Skipping state backup."
  exit 0
}

PRIMARY_BUCKET="$(jq -r '.state_bucket_primary' <<<"$T")"
REPLICA_BUCKET="$(jq -r '.state_bucket_replica' <<<"$T")"
KEY="$(jq -r '.state_key' <<<"$T")"
PRIMARY_EP="$(jq -r '.primary_endpoint' <<<"$T")"
PRIMARY_REGION="$(jq -r '.primary_region' <<<"$T")"
REPLICA_EP="$(jq -r '.replica_endpoint' <<<"$T")"
REPLICA_REGION="$(jq -r '.replica_region' <<<"$T")"

# Replica creds default to the primary creds (dev: same provider).
BACKUP_AWS_ACCESS_KEY_ID="${BACKUP_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
BACKUP_AWS_SECRET_ACCESS_KEY="${BACKUP_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Download the ciphertext from primary, re-upload to the replica (cross-creds + SSE).
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
  aws s3 cp "s3://$PRIMARY_BUCKET/$KEY" "$WORK/state" \
    --endpoint-url "$PRIMARY_EP" --region "$PRIMARY_REGION" >/dev/null

AWS_ACCESS_KEY_ID="$BACKUP_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$BACKUP_AWS_SECRET_ACCESS_KEY" \
  aws s3 cp "$WORK/state" "s3://$REPLICA_BUCKET/$KEY" \
    --endpoint-url "$REPLICA_EP" --region "$REPLICA_REGION" --sse AES256 >/dev/null

echo "✓ tfstate replicated (still client-encrypted): s3://$PRIMARY_BUCKET/$KEY → s3://$REPLICA_BUCKET/$KEY"
