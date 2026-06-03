#!/usr/bin/env bash
# ==============================================================================
# OpenAether — emit the `-backend-config=...` flags for `tofu init`, DERIVED from
# a cluster's tfvars (the single source of truth, so dev/prod never drift).
#
#   bucket  = s3-<project>-<provider>-tfstate-<env>   (project = cluster_name's 1st segment)
#   key     = <cluster_name>.tfstate
#   region / endpoint = s3_primary_*
#
# Usage:
#   tofu init -reconfigure $(scripts/tf-backend.sh envs/management-scaleway.tfvars)
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

TFVARS="${1:?usage: tf-backend.sh <cluster.tfvars>}"
[ -f "$TFVARS" ] || { echo "tf-backend.sh: tfvars not found: $TFVARS" >&2; exit 1; }

CLUSTER="$(tfv "$TFVARS" cluster_name)"
ENVN="$(tfv "$TFVARS" environment)"
EP="$(tfv "$TFVARS" s3_primary_endpoint)"
REGION="$(tfv "$TFVARS" s3_primary_region)"
PROVIDER="$(tfv_provider "$TFVARS")"
provider_pu "$PROVIDER" >/dev/null || { echo "tf-backend.sh: could not detect provider in $TFVARS" >&2; exit 1; }

[ -n "$CLUSTER" ] && [ -n "$ENVN" ] && [ -n "$EP" ] && [ -n "$REGION" ] || {
  echo "tf-backend.sh: missing cluster_name/environment/s3_primary_* in $TFVARS" >&2; exit 1; }

BUCKET="$(oa_state_bucket "${CLUSTER%%-*}" "$PROVIDER" "$ENVN")"

# Space-separated; values contain no spaces, so the caller's $(...) word-splits cleanly.
printf -- '-backend-config=bucket=%s -backend-config=key=%s.tfstate -backend-config=region=%s -backend-config=endpoint=%s' \
  "$BUCKET" "$CLUSTER" "$REGION" "$EP"
