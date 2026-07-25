#!/usr/bin/env bash
# ==============================================================================
# OpenAether — encrypted etcd snapshot → TWO object stores (client-side crypto)
#
# GitOps makes the cluster content reconstructible by design (Flux re-applies
# everything) — this snapshot is an RTO shortcut and a safety net for the few
# objects that live only in etcd (Secrets written by Jobs, ESO targets, PVC
# bindings…). Complements, does not replace, the in-cluster backups
# (OpenAether-apps/apps/base/backup: OpenBao raft + CNPG dumps via restic).
#
# WHAT IT DOES
#   1. `talosctl etcd snapshot` from the first healthy control plane, through
#      the SSH tunnels (CP i → localhost:50000+i, cf. talos-tunnels.sh).
#   2. CLIENT-side encrypt with gpg (symmetric AES-256, authenticated, hardened
#      S2K) using the SAME passphrase as the tfstate (TF_VAR_encryption_passphrase)
#      — identical model to backup-artifacts.sh.
#   3. Upload to the PRIMARY and REPLICA artifact buckets (backup_targets
#      output), S3 SSE layered on top, under backups/etcd/.
#   4. Retention: keep the most recent $KEEP snapshots per bucket (default 30).
#
# PREREQUISITES
#   * run from infrastructure/opentofu/cluster (`task etcd-snapshot` does this),
#     tofu init done, tunnels open, ./talosconfig present.
#   * TF_VAR_encryption_passphrase in env; provider creds for primary + replica
#     resolved by ../lib/common.sh::s3_cred (cross-provider <PU>_BACKUP_AWS_*).
#
# RESTORE (disaster only — wipes current etcd; prefer GitOps reconvergence):
#   gpg -d etcd-<ts>.snap.gpg > etcd.snap
#   talosctl -e <cp> -n <cp-ip> bootstrap --recover-from=etcd.snap
#
# Usage: etcd-snapshot.sh   (env: KEEP=30, TALOSCONFIG=./talosconfig)
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

KEEP="${KEEP:-30}"
TALOSCONFIG_FILE="${TALOSCONFIG:-./talosconfig}"

for bin in tofu jq talosctl aws gpg; do
  command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required" >&2; exit 1; }
done
[ -f "$TALOSCONFIG_FILE" ] || { echo "✗ talosconfig not found: $TALOSCONFIG_FILE" >&2; exit 1; }
PASSPHRASE="${TF_VAR_encryption_passphrase:?✗ TF_VAR_encryption_passphrase required (same passphrase as the tfstate)}"
export TALOSCONFIG="$TALOSCONFIG_FILE"
oa_aws_compat

# --- targets & creds (single source of truth: backup_targets output) ---------
T="$(tofu output -json backup_targets 2>/dev/null || echo 'null')"
[ "$T" != "null" ] && [ -n "$T" ] || { echo "✗ no backup_targets output — apply the infra first" >&2; exit 1; }
PRIMARY_BUCKET="$(jq -r '.artifact_bucket_primary' <<<"$T")"
REPLICA_BUCKET="$(jq -r '.artifact_bucket_replica' <<<"$T")"
PRIMARY_EP="$(jq -r '.primary_endpoint' <<<"$T")";  PRIMARY_REGION="$(jq -r '.primary_region' <<<"$T")"
REPLICA_EP="$(jq -r '.replica_endpoint' <<<"$T")";  REPLICA_REGION="$(jq -r '.replica_region' <<<"$T")"
PROVIDER="$(jq -r '.provider' <<<"$T")"

PRIMARY_AK="$(s3_cred "$PROVIDER" primary ak)"; PRIMARY_SK="$(s3_cred "$PROVIDER" primary sk)"
BACKUP_AK="$(s3_cred "$PROVIDER" backup ak)";   BACKUP_SK="$(s3_cred "$PROVIDER" backup sk)"

mapfile -t CP_IPS < <(tofu output -json 2>/dev/null | jq -r '.control_plane_private_ips.value[]? // empty')
[ ${#CP_IPS[@]} -gt 0 ] || { echo "✗ no control_plane_private_ips output — is the infra deployed?" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
WORK="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME" "$WORK"' EXIT

# --- 1) snapshot from the first healthy CP (tunnels: CP i → 50000+i) ---------
SNAP="$WORK/etcd.snap"
took=""
for k in "${!CP_IPS[@]}"; do
  ep="127.0.0.1:$((50000 + k))"; ip="${CP_IPS[$k]}"
  if talosctl -e "$ep" -n "$ip" etcd snapshot "$SNAP" >/dev/null 2>&1; then
    took="cp-${k} (${ip})"; break
  fi
done
[ -n "$took" ] || { echo "✗ etcd snapshot failed on every CP — tunnels open? (talos-tunnels.sh open)" >&2; exit 1; }
echo "✓ etcd snapshot taken via ${took} ($(du -h "$SNAP" | cut -f1))"

# --- 2) client-side encrypt (same model as backup-artifacts.sh) --------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$WORK/etcd-${TS}.snap.gpg"
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
    --symmetric --cipher-algo AES256 -o "$OUT" "$SNAP" 3< <(printf '%s' "$PASSPHRASE")

# --- 3) upload to both stores + 4) retention ---------------------------------
put_and_prune() { # bucket endpoint region ak sk
  local bucket="$1" ep="$2" region="$3" ak="$4" sk="$5"
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3 cp "$OUT" "s3://${bucket}/backups/etcd/$(basename "$OUT")" \
      --endpoint-url "$ep" --region "$region" --sse AES256 >/dev/null

  # Retention: timestamped names sort lexically == chronologically.
  local old
  old="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3api list-objects-v2 --bucket "$bucket" --prefix "backups/etcd/etcd-" \
      --endpoint-url "$ep" --region "$region" \
      --query 'Contents[].Key' --output json 2>/dev/null \
    | jq -r '. // [] | sort | .[0:(length - '"$KEEP"')] | .[]?' )"
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
      aws s3 rm "s3://${bucket}/${key}" --endpoint-url "$ep" --region "$region" >/dev/null
  done <<<"$old"
}

put_and_prune "$PRIMARY_BUCKET" "$PRIMARY_EP" "$PRIMARY_REGION" "$PRIMARY_AK" "$PRIMARY_SK"
put_and_prune "$REPLICA_BUCKET" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AK"  "$BACKUP_SK"

echo "✓ Encrypted etcd snapshot → s3://${PRIMARY_BUCKET}/backups/etcd/ + s3://${REPLICA_BUCKET}/backups/etcd/ (keep ${KEEP})"
