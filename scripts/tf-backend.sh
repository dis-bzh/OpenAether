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
#   tofu init -reconfigure $(scripts/tf-backend.sh envs/management-scw.tfvars)
# ==============================================================================
set -euo pipefail

TFVARS="${1:?usage: tf-backend.sh <cluster.tfvars>}"
[ -f "$TFVARS" ] || { echo "tf-backend.sh: tfvars not found: $TFVARS" >&2; exit 1; }

val() {
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//'
}

CLUSTER="$(val cluster_name)"
ENVN="$(val environment)"
EP="$(val s3_primary_endpoint)"
REGION="$(val s3_primary_region)"

PL="$(grep -E '^[[:space:]]*(scaleway|ovh|outscale)[[:space:]]*=' "$TFVARS" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*([a-z]+).*/\1/')"
case "$PL" in
  scaleway) P=scw ;;
  ovh)      P=ovh ;;
  outscale) P=outscale ;;
  *) echo "tf-backend.sh: could not detect provider from node_distribution in $TFVARS" >&2; exit 1 ;;
esac

[ -n "$CLUSTER" ] && [ -n "$ENVN" ] && [ -n "$EP" ] && [ -n "$REGION" ] || {
  echo "tf-backend.sh: missing cluster_name/environment/s3_primary_* in $TFVARS" >&2; exit 1; }

BUCKET="s3-${CLUSTER%%-*}-${P}-tfstate-${ENVN}"

# Space-separated; values contain no spaces, so the caller's $(...) word-splits cleanly.
printf -- '-backend-config=bucket=%s -backend-config=key=%s.tfstate -backend-config=region=%s -backend-config=endpoint=%s' \
  "$BUCKET" "$CLUSTER" "$REGION" "$EP"
