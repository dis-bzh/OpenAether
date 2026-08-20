#!/usr/bin/env bash
# ==============================================================================
# Does this object store honour the conditional write OpenTofu's S3 lock needs?
#
# `use_lockfile = true` acquires the state lock by PUTting a .tflock object with
# `If-None-Match: *` — the write must FAIL when the object already exists, or
# two runs both believe they hold the lock. That is documented for AWS S3
# (opentofu.org/docs/language/settings/backends/s3). Nothing documents whether
# Scaleway, OVH or Outscale implement it, and a store that silently ACCEPTS the
# second write gives a lock that never locks — worse than no lock, because the
# configuration then claims one.
#
# So ask each store. Three requests per provider, on a bucket the project
# already owns, and the probe object is deleted on the way out.
#
#   PASS  the second conditional PUT is refused (412 PreconditionFailed)
#   FAIL  it is accepted — use_lockfile would be decorative there
#
# Usage: probe-s3-conditional-write.sh [provider ...]   (default: all three)
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/lib/common.sh
oa_aws_compat

command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required" >&2; exit 1; }

PASS=0; FAIL=0; UNK=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
unk() { printf '  \033[33m?\033[0m %s\n' "$*"; UNK=$((UNK + 1)); }

probe() { # <provider>
  local p="$1" tfvars bucket ep region ak sk key rc1 rc2 out
  tfvars="infrastructure/opentofu/cluster/envs/management-${p}.tfvars"
  [ -f "$tfvars" ] || { unk "${p}: no ${tfvars##*/} — not probed"; return; }

  ep="$(tfv "$tfvars" s3_primary_endpoint)"
  region="$(tfv "$tfvars" s3_primary_region)"
  bucket="$(oa_state_bucket "$(oa_project "$(tfv "$tfvars" cluster_name)" \
            "$(tfv "$tfvars" bucket_suffix)")" "$p" "$(tfv "$tfvars" environment)")"
  ak="$(s3_cred "$p" primary ak)"; sk="$(s3_cred "$p" primary sk)"
  [ -n "$ak" ] && [ -n "$bucket" ] && [ -n "$ep" ] || { unk "${p}: no credentials or bucket — not probed"; return; }

  key="_oa-lock-probe-$$"
  # First write: the object does not exist, so If-None-Match:* must succeed.
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3api put-object --bucket "$bucket" --key "$key" --if-none-match '*' \
      --endpoint-url "$ep" --region "$region" >/dev/null 2>&1
  rc1=$?
  if [ "$rc1" -ne 0 ]; then
    unk "${p}: the FIRST conditional write failed — the store may not accept --if-none-match at all"
    AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
      aws s3api delete-object --bucket "$bucket" --key "$key" \
        --endpoint-url "$ep" --region "$region" >/dev/null 2>&1
    return
  fi

  # Second write: the object EXISTS now. This is the one that must be refused.
  out="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3api put-object --bucket "$bucket" --key "$key" --if-none-match '*' \
      --endpoint-url "$ep" --region "$region" 2>&1)"
  rc2=$?

  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
    aws s3api delete-object --bucket "$bucket" --key "$key" \
      --endpoint-url "$ep" --region "$region" >/dev/null 2>&1

  if [ "$rc2" -ne 0 ]; then
    case "$out" in
      *PreconditionFailed*|*412*) ok "${p}: the second conditional write is refused — use_lockfile would really lock" ;;
      *) ok "${p}: the second conditional write is refused (${out##*$'\n'})" ;;
    esac
  else
    bad "${p}: the second conditional write was ACCEPTED — use_lockfile would be decorative here"
  fi
}

echo "▶ Conditional-write probe (the mechanism behind use_lockfile)"
# An array, not "${@:-a b c}": quoted, that default expands to ONE word and the
# probe then looks for a tfvars called "scaleway ovh outscale".
TARGETS=("$@")
[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=(scaleway ovh outscale)
for p in "${TARGETS[@]}"; do probe "$p"; done
echo
printf '%s honour it, %s do not, %s could not be asked\n' "$PASS" "$FAIL" "$UNK"
[ "$FAIL" -eq 0 ]
