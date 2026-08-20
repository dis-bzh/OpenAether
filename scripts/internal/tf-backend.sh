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
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

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

BUCKET="$(oa_state_bucket "$(oa_project "$CLUSTER" "$(tfv "$TFVARS" bucket_suffix)")" "$PROVIDER" "$ENVN")"

# Space-separated; values contain no spaces, so the caller's $(...) word-splits cleanly.
# State locking, and ONLY where it is real. `use_lockfile` acquires the lock by
# PUTting a .tflock object with `If-None-Match: *`, so it depends on the store
# honouring conditional writes. MEASURED 2026-08-20 with the same client against
# all three (scripts/dev/probe-s3-conditional-write.sh): Scaleway and OVH refuse
# the second write, Outscale ACCEPTS it. Enabling it there would print
# "Acquiring state lock" and hold nothing — the protection you believe you have.
#
# Keyed on the ENDPOINT, not the cluster's provider: a Proxmox cluster keeps its
# state on somebody else's S3, and it is that store which either locks or does
# not. Same reasoning as the backup credentials in lib/common.sh::s3_cred.
LOCK=""
case "$(provider_of_endpoint "$EP")" in
  scaleway | ovh) LOCK=" -backend-config=use_lockfile=true" ;;
esac

printf -- '-backend-config=bucket=%s -backend-config=key=%s.tfstate -backend-config=region=%s -backend-config=endpoint=%s%s' \
  "$BUCKET" "$CLUSTER" "$REGION" "$EP" "$LOCK"
