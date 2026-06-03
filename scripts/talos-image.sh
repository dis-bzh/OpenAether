#!/usr/bin/env bash
# ==============================================================================
# OpenAether — build + publish the Talos image for a provider (decoupled root).
#
# The image is built once per Talos version and reused by every cluster/env on
# that provider. Building an image NEVER touches deployed cluster infra (separate
# state), so it works whether or not infra is already deployed.
#
# Consistent cred rule: working on provider X uses AWS_* = X's S3 keys (for the
# build state, same as deploying a cluster on X) PLUS X's compute creds:
#   scaleway -> SCW_* ; ovh -> OS_* ; outscale -> OSC_*. Plus TF_VAR_encryption_passphrase.
#
# State: s3-openaether-<provider>-talos-image / talos-image.tfstate (its own bucket
# per provider — building one provider's image never disturbs another's).
#
# Usage:
#   ./scripts/talos-image.sh <scaleway|ovh|outscale> [talos_version]
#   task talos-image PROVIDER=ovh [VERSION=v1.13.3]
# ==============================================================================
set -euo pipefail

RAW="${1:?usage: talos-image.sh <scaleway|ovh|outscale> [talos_version]}"
VERSION="${2:-v1.13.3}"
P="$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]')"
case "$P" in
  scw | scaleway) P=scaleway; TGT=scaleway; SREGION=fr-par;    SEP="https://s3.fr-par.scw.cloud" ;;
  ovh)            TGT=ovh;      SREGION=eu-west-par;        SEP="https://s3.eu-west-par.io.cloud.ovh.net" ;;
  outscale)       TGT=outscale; SREGION=eu-west-2; SEP="https://oos.eu-west-2.outscale.com" ;;
  *) echo "✗ unknown provider: $RAW (expected scaleway|ovh|outscale)"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infrastructure/opentofu/talos-image" && pwd)"
command -v tofu >/dev/null 2>&1 || { echo "✗ tofu required"; exit 1; }
command -v aws  >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
oa_aws_compat

# Resolve the target provider's S3 creds into AWS_* (aws CLI + tofu S3 backend),
# via lib/common.sh::s3_cred — namespaced per provider, no ambient AWS_* fallback.
PU="$(provider_pu "$TGT")"
AWS_ACCESS_KEY_ID="$(s3_cred "$TGT" primary ak)"
AWS_SECRET_ACCESS_KEY="$(s3_cred "$TGT" primary sk)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
[ -n "$AWS_ACCESS_KEY_ID" ] || {
  echo "✗ no S3 creds for '${TGT}': set ${PU}_AWS_ACCESS_KEY_ID + ${PU}_AWS_SECRET_ACCESS_KEY"
  [ "$TGT" = ovh ] && echo "  (OVH S3 needs SEPARATE keys: 'openstack ec2 credentials create' — not OS_PASSWORD)"
  exit 1
}
echo "  S3 creds: ${PU}_AWS_* (${AWS_ACCESS_KEY_ID:0:6}…)"

# Outscale's API (CreateSnapshot/CreateImage) uses the same AK/SK as OOS — feed
# them to the provider explicitly (TF_VAR_*) so it doesn't depend on OSC_* names.
if [ "$P" = outscale ]; then
  export TF_VAR_outscale_access_key_id="$AWS_ACCESS_KEY_ID"
  export TF_VAR_outscale_secret_key_id="$AWS_SECRET_ACCESS_KEY"
fi

STATE_BUCKET="s3-openaether-${TGT}-talos-image"

ensure() { # bucket
  aws s3api head-bucket --bucket "$1" --endpoint-url "$SEP" --region "$SREGION" >/dev/null 2>&1 \
    || aws s3 mb "s3://$1" --endpoint-url "$SEP" --region "$SREGION" >/dev/null
  echo "  ✓ bucket $1"
}

echo "▶ Ensuring talos-image state bucket on ${TGT} (${STATE_BUCKET})"
ensure "$STATE_BUCKET"

APPLY_VARS=(-var "target_provider=$TGT" -var "talos_version=$VERSION")
case "$P" in
  scaleway | outscale)
    # Scaleway/Outscale stage the raw image in Object Storage for the snapshot import.
    STAGING="s3-openaether-${TGT}-talos-staging"
    ensure "$STAGING"
    APPLY_VARS+=(-var "staging_bucket=$STAGING" -var "region=$SREGION" -var "s3_endpoint=$SEP")
    ;;
esac

cd "$ROOT"
tofu init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=talos-image.tfstate" \
  -backend-config="region=$SREGION" \
  -backend-config="endpoint=$SEP"

tofu apply "${APPLY_VARS[@]}"

echo
echo "→ image_name: $(tofu output -raw image_name 2>/dev/null || echo '?')"
tofu output image_id 2>/dev/null || true
echo "  (Scaleway: cluster looks up by image_name; OVH/Outscale: put image_id in the cluster envs/*.tfvars)"
