#!/usr/bin/env bash
# ==============================================================================
# resolve-s3-cred.sh PROVIDER TYPE
#
# Outputs the S3 credential value for the given provider — same indirection
# logic as talos-image.sh and ensure-buckets.sh, so all scripts stay DRY.
# Used by the Taskfile (env: sh:) to set AWS_* before tofu init / tofu apply.
#
# PROVIDER : scw | scaleway | ovh | outscale
# TYPE     : ak (access key) | sk (secret key)
#
# Lookup order:
#   Primary  : ${PU}_AWS_ACCESS_KEY_ID → ${PU}_AWS_ACCESS_KEY → AWS_ACCESS_KEY_ID
#              → native API key (SCW_ACCESS_KEY, OSC_ACCESS_KEY)
# where PU = SCW | OVH | OUTSCALE
# ==============================================================================
set -euo pipefail

P="${1:?usage: resolve-s3-cred.sh <scw|ovh|outscale> <ak|sk>}"
TYPE="${2:?usage: resolve-s3-cred.sh <provider> <ak|sk>}"

case "$(printf '%s' "$P" | tr '[:upper:]' '[:lower:]')" in
  scw | scaleway) PU=SCW ;;
  ovh)            PU=OVH ;;
  outscale)       PU=OUTSCALE ;;
  *) printf 'resolve-s3-cred.sh: unknown provider: %s\n' "$P" >&2; exit 1 ;;
esac

if [ "$TYPE" = ak ]; then
  v1="${PU}_AWS_ACCESS_KEY_ID"; v2="${PU}_AWS_ACCESS_KEY"
  VAL="${!v1:-${!v2:-${AWS_ACCESS_KEY_ID:-}}}"
  case "$PU" in
    SCW)      VAL="${VAL:-${SCW_ACCESS_KEY:-}}" ;;
    OUTSCALE) VAL="${VAL:-${OSC_ACCESS_KEY:-}}" ;;
  esac
else
  v1="${PU}_AWS_SECRET_ACCESS_KEY"; v2="${PU}_AWS_SECRET_KEY"
  VAL="${!v1:-${!v2:-${AWS_SECRET_ACCESS_KEY:-}}}"
  case "$PU" in
    SCW)      VAL="${VAL:-${SCW_SECRET_KEY:-}}" ;;
    OUTSCALE) VAL="${VAL:-${OSC_SECRET_KEY:-}}" ;;
  esac
fi

printf '%s' "$VAL"
