#!/usr/bin/env bash
# ==============================================================================
# OpenAether — shared shell helpers (source this; do not execute)
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Single source of truth for: tfvars parsing, provider detection, the
# provider→prefix mapping, S3 credential resolution (primary + cross-provider
# backup), bucket-name convention, and AWS-CLI quirks. Keeps every script DRY
# and consistent — change a rule here, not in five places.
# ==============================================================================

# --- AWS CLI quirk: S3-compatible stores (OOS, OVH, Scaleway) reject the AWS
# CLI v2.23+ default trailing checksum. Call once before any `aws` command.
oa_aws_compat() {
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
}

# --- tfvars: read a top-level string assignment (key = "value"), ignore comments.
# Usage: tfv <tfvars-file> <key>
tfv() {
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//'
}

# --- Detect the active provider (scaleway|ovh|outscale|proxmox) from node_distribution.
# Usage: tfv_provider <tfvars-file>
tfv_provider() {
  grep -E '^[[:space:]]*(scaleway|ovh|outscale|proxmox)[[:space:]]*=' "$1" 2>/dev/null \
    | head -1 | sed -E 's/^[[:space:]]*([a-z]+).*/\1/'
}

# --- Provider (long or short) -> uppercase env prefix. Usage: provider_pu <prov>
provider_pu() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    scw | scaleway) printf 'SCW' ;;
    ovh)            printf 'OVH' ;;
    outscale)       printf 'OUTSCALE' ;;
    proxmox)        printf 'PROXMOX' ;;
    *) return 1 ;;
  esac
}

# --- Resolve an S3 credential value by variable indirection (no ambient AWS_*
# fallback — that silently used another provider's keys). Echoes the value.
#   s3_cred <provider> <primary|backup> <ak|sk>
#   primary : <PU>_AWS_<X>        -> <PU>_AWS_<Xalt>        -> native API keys
#   backup  : <PU>_BACKUP_AWS_<X> -> <PU>_BACKUP_AWS_<Xalt> -> BACKUP_AWS_<X> -> primary
# where PU = SCW|OVH|OUTSCALE.  Both _ID and non-_ID name forms accepted.
# Native API keys: Scaleway & Outscale S3 == API keys (SCW_*/OSC_*); OVH needs
# dedicated S3 keys (no native fallback).
s3_cred() {
  local prov="$1" kind="$2" type="$3" pu suffix alt val v1 v2 g
  pu="$(provider_pu "$prov")" || { echo "s3_cred: unknown provider '$prov'" >&2; return 1; }
  if [ "$type" = ak ]; then suffix=ACCESS_KEY_ID; alt=ACCESS_KEY
  else suffix=SECRET_ACCESS_KEY; alt=SECRET_KEY; fi

  if [ "$kind" = primary ]; then
    v1="${pu}_AWS_${suffix}"; v2="${pu}_AWS_${alt}"
    val="${!v1:-${!v2:-}}"
    if [ -z "$val" ]; then
      case "$pu" in
        SCW)      [ "$type" = ak ] && val="${SCW_ACCESS_KEY:-}" || val="${SCW_SECRET_KEY:-}" ;;
        OUTSCALE) [ "$type" = ak ] && val="${OSC_ACCESS_KEY:-}" || val="${OSC_SECRET_KEY:-}" ;;
      esac
    fi
  else # backup
    v1="${pu}_BACKUP_AWS_${suffix}"; v2="${pu}_BACKUP_AWS_${alt}"
    val="${!v1:-${!v2:-}}"
    [ -n "$val" ] || { g="BACKUP_AWS_${suffix}"; val="${!g:-}"; }
    [ -n "$val" ] || val="$(s3_cred "$prov" primary "$type")"
  fi
  printf '%s' "$val"
}

# --- Bucket-name convention (mirrors cluster/backup.tf locals).
#   project = cluster_name's first segment, provider = scaleway|ovh|outscale
oa_state_bucket() { printf 's3-%s-%s-tfstate-%s' "$1" "$2" "$3"; }            # project provider env
oa_artifact_bucket() { printf 's3-%s-%s-%s-%s' "$1" "$2" "$3" "$4"; }         # project provider role env
