#!/usr/bin/env bash
# OpenAether — build + publish the Talos image for a provider (decoupled root).
#
# Built once per Talos version, reused by every cluster on that provider. Its
# own state (one bucket per provider) means building never touches deployed
# cluster infra.
#
# Credentials: AWS_* = the provider's S3 keys, plus its compute creds
# (scaleway SCW_*, ovh OS_*, outscale OSC_*, proxmox PROXMOX_VE_*) and
# TF_VAR_encryption_passphrase.
#
# Usage:
#   ./scripts/bootstrap/talos-image.sh <provider> [talos_version] [--ensure]
#   task talos-image PROVIDER=ovh [VERSION=v1.13.4]
#
# --ensure: idempotence gate for `task up` — plans first and only applies on a
#   real change, so a rerun with the image already published costs nothing.
set -euo pipefail

ENSURE=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --ensure) ENSURE=true ;;
    *) ARGS+=("$a") ;;
  esac
done

RAW="${ARGS[0]:?usage: talos-image.sh <scaleway|ovh|outscale|proxmox> [talos_version] [--ensure]}"
VERSION="${ARGS[1]:-v1.13.4}"
P="$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]')"
case "$P" in
  scw | scaleway) P=scaleway; TGT=scaleway; SREGION=fr-par;    SEP="https://s3.fr-par.scw.cloud" ;;
  ovh)            TGT=ovh;      SREGION=eu-west-par;        SEP="https://s3.eu-west-par.io.cloud.ovh.net" ;;
  outscale)       TGT=outscale; SREGION=eu-west-2; SEP="https://oos.eu-west-2.outscale.com" ;;
  proxmox)        TGT=proxmox;  SREGION="${PROXMOX_S3_REGION:-fr-par}"; SEP="${PROXMOX_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}" ;;
  *) echo "✗ unknown provider: $RAW (expected scaleway|ovh|outscale|proxmox)"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/talos-image" && pwd)"
command -v tofu >/dev/null 2>&1 || { echo "✗ tofu required"; exit 1; }
command -v aws  >/dev/null 2>&1 || { echo "✗ aws CLI required"; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
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

# Proxmox downloads server-side onto the host's datastore (no local convert
# step), so it needs the bpg provider's own creds — fail fast if missing
# rather than let `tofu apply` surface an opaque auth error.
if [ "$P" = proxmox ]; then
  [ -n "${PROXMOX_VE_ENDPOINT:-}" ] && [ -n "${PROXMOX_VE_API_TOKEN:-}" ] || {
    echo "✗ Proxmox creds missing: export PROXMOX_VE_ENDPOINT + PROXMOX_VE_API_TOKEN"
    echo "  (PROXMOX_VE_INSECURE=true for a self-signed 8006 cert)"
    exit 1
  }
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
  proxmox)
    # No staging bucket — the download lands straight on the host's datastore.
    # PROXMOX_NODE_NAMES is comma-separated (e.g. "pve1,pve2,pve3"); match
    # node_distribution.proxmox.node_names in the cluster envs/*.tfvars.
    IFS=',' read -ra PMX_NODES <<<"${PROXMOX_NODE_NAMES:-pve1}"
    PMX_NODES_HCL="[$(printf '"%s",' "${PMX_NODES[@]}" | sed 's/,$//')]"
    APPLY_VARS+=(
      -var "proxmox_node_names=${PMX_NODES_HCL}"
      -var "proxmox_iso_datastore_id=${PROXMOX_ISO_DATASTORE_ID:-local}"
    )
    ;;
esac

cd "$ROOT"
tofu init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=talos-image.tfstate" \
  -backend-config="region=$SREGION" \
  -backend-config="endpoint=$SEP"

if [ "$ENSURE" = true ]; then
  echo "▶ --ensure: checking whether the image needs (re)building..."
  PLAN_EXIT=0
  tofu plan -detailed-exitcode "${APPLY_VARS[@]}" || PLAN_EXIT=$?
  case "$PLAN_EXIT" in
    0) echo "✓ image already up to date — skipping apply" ;;
    # --ensure is the non-interactive idempotence gate for `task up`, so the
    # apply must not stop to prompt for approval (it would EOF and abort the
    # pipeline). The plain `task talos-image` path below stays interactive.
    2) tofu apply -auto-approve "${APPLY_VARS[@]}" ;;
    *)
      echo "✗ tofu plan failed (exit ${PLAN_EXIT})"
      exit 1
      ;;
  esac
else
  tofu apply "${APPLY_VARS[@]}"
fi

echo
echo "→ image_name: $(tofu output -raw image_name 2>/dev/null || echo '?')"
tofu output image_id 2>/dev/null || true
[ "$P" = proxmox ] && tofu output image_file_id 2>/dev/null
echo "  (All three clouds look the image up by name — leave image_id unset in the"
echo "   cluster envs/*.tfvars and a version bump needs no edit. Proxmox:"
echo "   talos_image_file_id follows the same convention.)"

# ──────────────────────────────────────────────────────────────────────────────
# A pinned image_id is OPTIONAL on OVH and Outscale (null looks the name up, the
# same way Scaleway does) and it is a trap: nothing compared the pin to the image
# this lane publishes, so a rebuild left a stale id behind and `task up` — which
# runs this script first, learns the right id, prints it, then deploys with the
# wrong one — failed at server creation with "Can not find requested image",
# after the network and the bastion had been created. Refuse before the spend.
#
# The remedy printed first is DELETING the pin, not updating it: updating keeps
# the hand-copy step, which is what makes an unattended upgrade impossible on
# these two providers (measured 2026-08-15 — the guard fired mid-run on OVH).
# ──────────────────────────────────────────────────────────────────────────────
if [ "$P" = ovh ] || [ "$P" = outscale ]; then
  WANT="$(tofu output -raw image_id 2>/dev/null || true)"
  ENVS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/opentofu/cluster/envs" && pwd)"
  stale=0
  for f in "$ENVS"/*-"$P".tfvars; do
    [ -e "$f" ] || continue
    # Anchored, because `grep -o 'image_id...'` strips the `bastion_` prefix
    # before the filter downstream can see it: with no Talos pin left in the
    # file, the bastion's own image was read as the pin and this guard refused
    # the very configuration it recommends (measured on OVH, 2026-08-15).
    HAVE="$(grep -E '^[[:space:]]*image_id[[:space:]]*=' "$f" \
            | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$WANT" ] && [ -n "$HAVE" ] && [ "$WANT" != "$HAVE" ] || continue
    echo "✗ $(basename "$f") pins image_id = $HAVE" >&2
    echo "  but the image this lane just resolved is $WANT." >&2
    echo "  Deploying would fail at server creation, after the bill." >&2
    echo "  Preferred: drop the pin so the name resolves it, here and on every bump:" >&2
    echo "    sed -i '/^[[:space:]]*image_id[[:space:]]*=/d' $f" >&2
    echo "  Or, to keep pinning this exact image:" >&2
    echo "    sed -i 's|$HAVE|$WANT|' $f" >&2
    stale=1
  done
  [ "$stale" -eq 0 ] || exit 1
fi
