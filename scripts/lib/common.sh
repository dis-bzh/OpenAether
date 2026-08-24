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

# --- Can sudo actually be USED here, or does it merely exist? -----------------
# `command -v sudo` answers the wrong question, and eight places asked it. On a
# workstation where /usr/local/bin is not writable and sudo wants a password,
# every installer chose the sudo branch and then died on a prompt nobody could
# answer — under `set -e` that ends the whole bootstrap. Measured 2026-08-24.
# Same shape as asking whether a binary exists rather than which version it is.
oa_sudo_usable() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true 2>/dev/null && return 0
  [ -t 0 ]   # a human is here and can be asked
}

# --- Where to install a binary. Echoes the directory. -------------------------
# /usr/local/bin when it is writable or reachable with a usable sudo; otherwise
# ~/.local/bin, which needs no privilege at all.
oa_bin_dir() {
  if [ -w /usr/local/bin ] || oa_sudo_usable; then
    printf '/usr/local/bin'
  else
    printf '%s/.local/bin' "${HOME}"
  fi
}

# --- The sudo prefix needed to write into <dir>. Echoes "sudo" or nothing. ----
# A directory that does not exist yet is judged by its parent, so creating
# ~/.local/bin does not ask for a password.
oa_sudo_for() {
  local d="${1:?usage: oa_sudo_for <dir>}"
  [ -d "$d" ] || d="$(dirname "$d")"
  [ -w "$d" ] && return 0
  oa_sudo_usable && printf 'sudo'
}

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
# Which provider owns an S3 endpoint. The BACKUP store is often not the cluster's
# own cloud, and its keys belong to whoever holds the bucket — see s3_cred.
# Empty (not an error) for anything unrecognised: a custom or self-hosted S3.
provider_of_endpoint() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    *.scw.cloud*)        printf 'scaleway' ;;
    *.outscale.com*)     printf 'outscale' ;;
    *.io.cloud.ovh.net*) printf 'ovh' ;;
    *) return 0 ;;
  esac
}

# Picks the credential AND names the variable it came from, tab-separated, so a
# failure can say "OUTSCALE_BACKUP_AWS_ACCESS_KEY_ID is rejected" instead of
# leaving the operator to guess which of six pairs was tried.
_s3_cred_pick() {
  local prov="$1" kind="$2" type="$3" ep="${4:-}" pu suffix alt v1 v2 g rprov rpu
  pu="$(provider_pu "$prov")" || { echo "s3_cred: unknown provider '$prov'" >&2; return 1; }
  if [ "$type" = ak ]; then suffix=ACCESS_KEY_ID; alt=ACCESS_KEY
  else suffix=SECRET_ACCESS_KEY; alt=SECRET_KEY; fi

  if [ "$kind" = primary ]; then
    v1="${pu}_AWS_${suffix}"; v2="${pu}_AWS_${alt}"
    if [ -n "${!v1:-}" ]; then printf '%s\t%s' "$v1" "${!v1}"; return 0; fi
    if [ -n "${!v2:-}" ]; then printf '%s\t%s' "$v2" "${!v2}"; return 0; fi
    case "$pu" in
      SCW)      v1=SCW_ACCESS_KEY;  v2=SCW_SECRET_KEY ;;
      OUTSCALE) v1=OSC_ACCESS_KEY;  v2=OSC_SECRET_KEY ;;
      *)        printf '\t'; return 0 ;;
    esac
    [ "$type" = ak ] || v1="$v2"
    printf '%s\t%s' "$v1" "${!v1:-}"
    return 0
  fi

  # BACKUP. Keys are named after the cloud that HOLDS THE BUCKET, not the cloud
  # the cluster runs on. Naming them after the cluster meant a Scaleway cluster
  # replicating to Outscale needed Outscale keys inside SCW_BACKUP_* — so the
  # variable name argued for the wrong value, and on 2026-08-19 it got one.
  # Given the endpoint, the store's own provider is asked FIRST.
  rprov="$(provider_of_endpoint "$ep")"
  rpu=""
  if [ -n "$rprov" ]; then rpu="$(provider_pu "$rprov")"; fi
  # Compared on the canonical prefix, so scw and scaleway are one provider.
  if [ -n "$rpu" ] && [ "$rpu" != "$pu" ]; then
    v1="${rpu}_BACKUP_AWS_${suffix}"; v2="${rpu}_BACKUP_AWS_${alt}"
    if [ -n "${!v1:-}" ]; then printf '%s\t%s' "$v1" "${!v1}"; return 0; fi
    if [ -n "${!v2:-}" ]; then printf '%s\t%s' "$v2" "${!v2}"; return 0; fi
    _s3_cred_pick "$rprov" primary "$type"
    return 0
  fi
  # Then the cluster-namespaced override, the generic one, and finally the
  # primary keys — which only authenticate when the store is the same cloud.
  v1="${pu}_BACKUP_AWS_${suffix}"; v2="${pu}_BACKUP_AWS_${alt}"
  if [ -n "${!v1:-}" ]; then printf '%s\t%s' "$v1" "${!v1}"; return 0; fi
  if [ -n "${!v2:-}" ]; then printf '%s\t%s' "$v2" "${!v2}"; return 0; fi
  g="BACKUP_AWS_${suffix}"
  if [ -n "${!g:-}" ]; then printf '%s\t%s' "$g" "${!g}"; return 0; fi
  _s3_cred_pick "$prov" primary "$type"
}

# s3_cred <provider> <primary|backup> <ak|sk> [endpoint]
s3_cred() { local r; r="$(_s3_cred_pick "$@")" || return 1; printf '%s' "${r#*$'\t'}"; }

# s3_cred_source <provider> <primary|backup> <ak|sk> [endpoint] -> variable name
s3_cred_source() { local r; r="$(_s3_cred_pick "$@")" || return 1; printf '%s' "${r%%$'\t'*}"; }

# --- Bucket-name convention (mirrors cluster/backup.tf locals).
#   project = cluster_name's first segment, plus bucket_suffix when set.
#
# WHY A SUFFIX EXISTS. S3 bucket names are NOT scoped to your account. Scaleway
# documents them as unique "in our whole platform … if a bucket exists already in
# one region, the name cannot be reused in another"; OVH says "Must be unique
# within OVHcloud"; Outscale, "unique for the whole Region". So the first person
# to create `s3-<project>-<provider>-tfstate-<env>` owns that name for everyone, and
# the second gets a creation failure on their very first billable command.
# `bucket_suffix` is the discriminator that makes a deployment portable. It is
# empty by default, which preserves the names already in use.
#
# It cannot be generated by OpenTofu: the state bucket must exist BEFORE tofu can
# run, so its name cannot come from tofu state. It lives in the tfvars, and
# `task bucket-suffix` prints a fresh one.
oa_project() { # <cluster_name> [bucket_suffix] — the bucket namespace
  local p="${1%%-*}"
  if [ -n "${2:-}" ]; then printf '%s-%s' "$p" "$2"; else printf '%s' "$p"; fi
}
oa_state_bucket() { printf 's3-%s-%s-tfstate-%s' "$1" "$2" "$3"; }            # project provider env
oa_artifact_bucket() { printf 's3-%s-%s-%s-%s' "$1" "$2" "$3" "$4"; }         # project provider role env

# --- Local port block for the per-node Talos API tunnels (CPs 50000+off+i,
# workers 50100+off+i). The ports were fixed, which meant one cluster at a time
# per workstation — a second provider's tunnels collide and talos-tunnels.sh
# refuses. TALOS_TUNNEL_OFFSET shifts the whole block so clusters can be brought
# up side by side. The cluster root needs the SAME number to know where to
# connect; Taskfile.yml derives TF_VAR_talos_tunnel_port_offset from this one
# variable so the two cannot drift.
oa_tunnel_offset() {
  local o="${TALOS_TUNNEL_OFFSET:-0}"
  [[ "$o" =~ ^[0-9]+$ ]] ||
    { echo "✗ TALOS_TUNNEL_OFFSET must be a non-negative integer, got: '$o'" >&2; return 1; }
  # Non-multiples of 200 would overlap the CP block of one cluster with the
  # worker block of another, and the collision would look like a flaky tunnel.
  (( o % 200 == 0 )) ||
    { echo "✗ TALOS_TUNNEL_OFFSET must be a multiple of 200, got: '$o'" >&2; return 1; }
  printf '%s' "$o"
}

# --- Is a Talos API endpoint REALLY there?
#
# "Bound" is not "working": `ssh -L` accepts the local connect itself and keeps
# listening after the far end dies, so `nc -z` calls a dead tunnel healthy. The
# TCP connect proves a listener; only the TLS handshake proves apid is behind
# it. A node in maintenance mode answers with a self-signed cert — still an
# answer, and still the right verdict.
#
# `timeout 5 bash -c` spawns bash on purpose: Task's own shell has no /dev/tcp.
# scripts/dev/test-endpoint-probe.sh breaks both halves and watches them go red.
oa_talos_endpoint_ok() { # <host> <port>
  command -v openssl >/dev/null 2>&1 || {
    echo "oa_talos_endpoint_ok: openssl is required — a probe that cannot run must not answer 'fine'" >&2
    return 2
  }
  timeout 5 bash -c ">/dev/tcp/${1}/${2}" 2>/dev/null || return 1
  timeout 10 openssl s_client -connect "${1}:${2}" -brief </dev/null 2>&1 |
    grep -qiE 'CONNECTION ESTABLISHED|Peer certificate|Protocol version'
}
