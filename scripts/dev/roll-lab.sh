#!/usr/bin/env bash
# OpenAether — iterate on the node roll without rebuilding the cluster.
#
# A roll fix used to be retested by deploying an 85-minute cluster in order to
# exercise its last twenty minutes. Two moves make that unnecessary, and both
# were used for real while fixing the roll on 2026-08-15:
#
#   resume                re-run the roll on the live cluster. `--upgrade` skips
#                         every node already on the target version, so a fixed
#                         roll costs minutes instead of a redeploy.
#   inject-cnpg-deadlock  reproduce in ~2 minutes the CNPG deadlock that cost
#                         four cloud rolls to characterise: cordon the node
#                         holding a primary and delete that pod. Its
#                         local-path-retain PVC pins it to the cordoned node, so
#                         it cannot come back and CNPG stalls mid-switchover.
#   status                what the next resume will see: node versions, cordons,
#                         CNPG state, the budgets that block a drain.
#   cleanup               uncordon what a roll or an injection left cordoned.
#
# This script BREAKS a running cluster on purpose. It therefore refuses to run
# anywhere that does not look disposable, and it needs a live cluster — neither
# is assumed, both are checked below.
#
# Usage: roll-lab.sh <resume|inject-cnpg-deadlock|status|cleanup> [provider]
#                    [--offset N] [--yes] [--dry-run]
#                    [--workers-only|--cp-only|--all]   (resume)
#                    [--cluster <ns>/<name>]            (inject-cnpg-deadlock)
#   The offset also comes from TALOS_TUNNEL_OFFSET, like every other script here.
# ==============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
hr()   { printf -- '─%.0s' {1..70}; printf '\n'; }

usage() {
  sed -n '/^# Usage:/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^===/d' >&2
}

# --- args --------------------------------------------------------------------
CMD="${1:-}"; shift || true
case "$CMD" in
  resume | inject-cnpg-deadlock | status | cleanup) ;;
  *) usage; exit 2 ;;
esac

PROVIDER=""
SCOPE="--workers-only"   # a lab retest is nearly always the worker roll
TARGET_CNPG=""
ASSUME_YES=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offset)  export TALOS_TUNNEL_OFFSET="${2:-}"; shift 2 ;;
    --cluster) TARGET_CNPG="${2:-}"; shift 2 ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --workers-only | --cp-only) SCOPE="$1"; shift ;;
    --all)     SCOPE=""; shift ;;
    -*) usage; die "unknown flag: $1" ;;
    *)  PROVIDER="$1"; shift ;;
  esac
done
PROVIDER="${PROVIDER:-scaleway}"
case "$PROVIDER" in
  scaleway | ovh | outscale | proxmox) ;;
  *) die "unknown provider: $PROVIDER (expected scaleway|ovh|outscale|proxmox)" ;;
esac
OFFSET="$(oa_tunnel_offset)" || exit 1
# The cluster root reads the same number from TF_VAR_talos_tunnel_port_offset;
# Taskfile.yml derives one from the other so they cannot drift, and a script
# calling the roll directly has to do the same.
export TF_VAR_talos_tunnel_port_offset="$OFFSET"

# rolling-replace.sh reads `envs/…` and `./kubeconfig` relative to the cwd, so
# the lab has to stand where the roll stands.
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
cd "$CLUSTER_DIR" || die "no cluster root at $CLUSTER_DIR"
TFVARS="envs/management-${PROVIDER}.tfvars"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")
INJECT_TIMEOUT="${INJECT_TIMEOUT:-300}"   # seconds to reach the deadlock shape

# --- the two things this script may not assume -------------------------------
# 1. Disposable. An environment name is a claim about the tfvars, not about the
#    cluster kubectl is pointed at, so it is only half the guard.
DISPOSABLE_ENVS="${ROLL_LAB_DISPOSABLE_ENVS:-dev test staging lab sandbox feint}"
# 2. Live, and the SAME cluster this state describes — otherwise "dev" was read
#    from one cluster's tfvars and the pod would be deleted on another's.
NODES_TSV=""   # name \t Ready \t cordoned|schedulable \t internal-ip \t osImage
CP_COUNT=0     # from the state, never assumed: a non-HA cluster has ONE control
WK_COUNT=0     # plane, and a check hardcoding three would refuse it for ever.

live_nodes_tsv() {
  local json
  # `|| true` here is the defect this repo keeps paying for: an apiserver that
  # did not answer would read as a cluster with no nodes, and every guard below
  # would pass on the empty set.
  json="$("${KCTL[@]}" get nodes -o json 2>/dev/null)" ||
    die "kubectl cannot reach the cluster via ${KUBECONFIG_FILE}.
  This script needs a LIVE cluster — it has nothing to say about a dead one.
  If the API goes through a tunnel, check the offset: this run used ${OFFSET}."
  jq -r '.items[] | [ .metadata.name,
      ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "?"),
      (if .spec.unschedulable then "cordoned" else "schedulable" end),
      ([.status.addresses[]? | select(.type=="InternalIP") | .address] | first // "-"),
      (.status.nodeInfo.osImage // "-") ] | @tsv' <<<"$json"
}

require_disposable_live_cluster() {
  [[ -f "$TFVARS" ]] || die "tfvars not found: ${CLUSTER_DIR}/${TFVARS}"
  [[ -f "$KUBECONFIG_FILE" ]] || die "kubeconfig not found: ${KUBECONFIG_FILE} (looked from ${CLUSTER_DIR})"
  for bin in kubectl jq tofu; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done

  local envn
  envn="$(tfv "$TFVARS" environment)"
  [[ -n "$envn" ]] || die "no environment= in ${TFVARS} — refusing to guess whether it is disposable"
  # shellcheck disable=SC2076  # literal match on the padded list, not a regex
  [[ " $DISPOSABLE_ENVS " == *" $envn "* ]] ||
    die "${TFVARS} says environment=\"${envn}\", which is not one of: ${DISPOSABLE_ENVS}.
  This script cordons nodes and deletes database pods on purpose. Point it at a
  throwaway cluster, or name that environment in ROLL_LAB_DISPOSABLE_ENVS."

  NODES_TSV="$(live_nodes_tsv)"
  [[ -n "$NODES_TSV" ]] || die "the apiserver answered with an EMPTY node list — that is not a cluster to experiment on"

  # Tie the kubeconfig to the state: at least one control-plane IP from the tofu
  # output must be a node's InternalIP. Without this the guard above proves only
  # that some file on disk said "dev".
  local outputs cp_ips ip
  outputs="$(tofu output -json 2>/dev/null)" || outputs='{}'
  cp_ips="$(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$outputs")"
  CP_COUNT="$(jq -r '(.control_plane_private_ips.value // []) | length' <<<"$outputs")"
  WK_COUNT="$(jq -r '(.worker_private_ips.value // []) | length' <<<"$outputs")"
  [[ -n "$cp_ips" ]] ||
    die "no control_plane_private_ips in \`tofu output\` (run from ${CLUSTER_DIR}, after \`tofu init\`).
  Without it there is nothing tying ${KUBECONFIG_FILE} to ${TFVARS}, and the
  disposable check above would be about a different cluster."
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    if awk -F'\t' -v want="$ip" '$4 == want { found = 1 } END { exit !found }' <<<"$NODES_TSV"; then
      ok "cluster is disposable (environment=${envn}) and live: $(wc -l <<<"$NODES_TSV") node(s)"
      return 0
    fi
  done <<<"$cp_ips"
  die "none of the control-plane IPs in \`tofu output\` is an InternalIP of the nodes
  ${KUBECONFIG_FILE} reaches — that kubeconfig is NOT the cluster ${TFVARS} describes."
}

announce() { hr; info "About to, on ${PROVIDER} (offset ${OFFSET}):"; printf '   %s\n' "$@"; hr; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "no terminal to confirm on — re-run with --yes if this really is a lab cluster"
  local a; read -rp "Proceed? [y/N] " a
  [[ "$a" == [yY] ]] || die "aborted by operator"
}

# --- CNPG ---------------------------------------------------------------------
cnpg_installed() { "${KCTL[@]}" get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; }

# "<ns> <name> <instances> <ready> <currentPrimary> <targetPrimary>" per cluster.
# ALWAYS read it into a variable — `while read … < <(cnpg_list)` would run the
# die below in a subshell, so a failed query would arrive as an empty list and
# every caller would carry on as if the cluster had no databases.
cnpg_list() {
  "${KCTL[@]}" get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.instances}{" "}{.status.readyInstances}{" "}{.status.currentPrimary}{" "}{.status.targetPrimary}{"\n"}{end}' 2>/dev/null ||
    die "the CNPG CRD exists but its clusters could not be listed — refusing to act blind"
}

# The injection is only worth anything if it produces the state the roll's own
# unstick fires on, so assert with THAT code — extracted from rolling-replace.sh
# the way scripts/dev/test-rolling-replace.sh does. A local copy of the four
# conditions would drift, and a drifted injection is worse than none.
load_roll_detector() {
  eval "$(awk '
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name ~ /^cnpg_(pod_state|deadlocked)$/) }
    inside { print }
    inside && /^\}/ { inside = 0 }' "$ROOT/scripts/ops/rolling-replace.sh")"
  if ! declare -F cnpg_deadlocked >/dev/null || ! declare -F cnpg_pod_state >/dev/null; then
    die "rolling-replace.sh no longer defines cnpg_pod_state/cnpg_deadlocked.
  This lab must exercise the roll's own detector, not a copy of it — update the
  extraction here (and in scripts/dev/test-rolling-replace.sh) to match."
  fi
}

# --- the target Talos version, i.e. what `resume` will skip -------------------
target_talos() {
  local tag
  tag="$(tofu output -raw installer_image 2>/dev/null || true)"
  [[ -n "$tag" ]] && { printf '%s' "${tag##*:}"; return 0; }
  tfv "$TFVARS" talos_version
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# The node tunnel ports this cluster actually uses (talos-tunnels.sh: CP
# 50000+offset+i, workers 50100+offset+i), one per line, absent ones only.
missing_tunnels() {
  local i
  for ((i = 0; i < CP_COUNT; i++)); do port_open $((50000 + OFFSET + i)) || echo "$((50000 + OFFSET + i))"; done
  for ((i = 0; i < WK_COUNT; i++)); do port_open $((50100 + OFFSET + i)) || echo "$((50100 + OFFSET + i))"; done
}

# ==============================================================================
# Subcommands
# ==============================================================================

do_status() {
  local target; target="$(target_talos)"
  hr; info "Nodes — target Talos ${target:-?} (resume skips those already on it)"
  awk -F'\t' -v t="${target:-none}" '
    { v = $5; sub(/.*\(/, "", v); sub(/\).*/, "", v)
      printf "  %-28s %-6s %-12s %-10s %s\n", $1, $2, $3, v,
             (t != "none" && v == t ? "on target" : "PENDING") }' <<<"$NODES_TSV"

  if cnpg_installed; then
    hr; info "CNPG"
    local ns name inst ready cur tgt clusters
    clusters="$(cnpg_list)"
    while read -r ns name inst ready cur tgt; do
      [[ -n "$ns" ]] || continue
      printf '  %-32s %s/%s ready   primary %s → %s\n' \
        "${ns}/${name}" "${ready:-?}" "${inst:-?}" "${cur:-none}" "${tgt:-none}"
    done <<<"$clusters"
    load_roll_detector
    local d; d="$(cnpg_deadlocked)"
    if [[ -n "$d" ]]; then warn "the roll's detector says DEADLOCKED: ${d}"
    else ok "the roll's detector sees no deadlock"; fi
  fi

  hr; info "Budgets that would block a drain (allowed=0 and short of a pod)"
  { "${KCTL[@]}" get pdb -A -o json 2>/dev/null || echo '{"items":[]}'; } |
    jq -r '.items[] | select((.status.disruptionsAllowed // 0) == 0)
           | select((.status.currentHealthy // 0) < (.status.expectedPods // 0))
           | "  \(.metadata.namespace)/\(.metadata.name)  healthy \(.status.currentHealthy)/\(.status.expectedPods)"'

  # A Kustomization left suspended is how rolling-replace fails halfway: it
  # suspends the CNPG owner for the roll and restores it on exit.
  local susp
  susp="$("${KCTL[@]}" get kustomizations.kustomize.toolkit.fluxcd.io -A \
    -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null || true)"
  [[ -n "$susp" ]] && warn "Flux Kustomizations left SUSPENDED: ${susp}" || true

  hr; info "Talos tunnels (offset ${OFFSET})"
  local gone; gone="$(missing_tunnels | tr '\n' ' ')"
  if [[ -n "$gone" ]]; then warn "not listening: ${gone}(resume needs all $((CP_COUNT + WK_COUNT)))"
  else ok "all $((CP_COUNT + WK_COUNT)) node tunnels are listening"; fi
}

do_resume() {
  local target; target="$(target_talos)"
  [[ -n "$target" ]] || die "no target Talos version (no installer_image output and no talos_version in ${TFVARS})"
  local pending
  pending="$(awk -F'\t' -v t="$target" '{ v = $5; sub(/.*\(/, "", v); sub(/\).*/, "", v)
             if (v != t) printf "%s ", $1 }' <<<"$NODES_TSV")"
  [[ -n "$pending" ]] || warn "every node already reports ${target} — the roll will skip all of them"

  local -a cmd=("$ROOT/scripts/ops/rolling-replace.sh" "$PROVIDER" --upgrade)
  [[ -n "$SCOPE" ]] && cmd+=("$SCOPE")
  # One prompt, ours: the roll runs unattended so a lab iteration is one command.
  [[ $DRY_RUN -eq 1 ]] && cmd+=(--dry-run) || cmd+=(--yes)

  # Tunnels are the roll's silent prerequisite: without them talosctl fails per
  # node, mid-roll, after the node has been cordoned and drained.
  local missing; missing="$(missing_tunnels | tr '\n' ' ')"
  if [[ -n "$missing" && $DRY_RUN -eq 0 ]]; then
    die "no Talos tunnel listening on ${missing}— open them first:
    SSH_KEY=~/.ssh/<key> ${ROOT}/scripts/bootstrap/talos-tunnels.sh open ${CLUSTER_DIR}
  (or run the roll through \`task rolling-replace\`, which opens them for you)."
  fi

  announce "run: ${cmd[*]}" \
           "nodes still to upgrade to ${target}: ${pending:-none}" \
           "nodes already on ${target} are SKIPPED — that is what makes this a retry"
  confirm
  exec "${cmd[@]}"
}

do_inject() {
  cnpg_installed || die "no CNPG on this cluster — nothing to deadlock"
  load_roll_detector

  local ns name inst ready cur tgt pick="" clusters
  clusters="$(cnpg_list)"
  while read -r ns name inst ready cur tgt; do
    [[ -n "$ns" && -n "$name" ]] || continue
    if [[ -n "$TARGET_CNPG" && "${ns}/${name}" != "$TARGET_CNPG" ]]; then continue; fi
    # Three READY instances minimum. The deadlock the roll unsticks needs a third
    # instance to elect — on a 2-instance cluster the detector is right not to
    # fire, so injecting there would produce a state nothing is meant to fix.
    if ! [[ "$inst" =~ ^[3-9][0-9]*$ && "$ready" == "$inst" ]]; then
      [[ -z "$TARGET_CNPG" ]] ||
        die "${ns}/${name} is ${ready:-?}/${inst:-?} — the injection needs 3+ instances, all ready"
      continue
    fi
    pick="$ns $name $cur"; break
  done <<<"$clusters"
  [[ -n "$pick" ]] || die "no healthy CNPG cluster with 3+ instances${TARGET_CNPG:+ matching ${TARGET_CNPG}} — nothing to inject into"
  read -r ns name cur <<<"$pick"
  [[ -n "$cur" ]] || die "${ns}/${name} reports no currentPrimary — it is already mid-election, not a clean start"

  local node
  node="$("${KCTL[@]}" -n "$ns" get pod "$cur" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ||
    die "could not read the node of ${ns}/${cur} — the apiserver did not answer"
  [[ -n "$node" ]] || die "primary pod ${ns}/${cur} does not exist — the cluster is already broken"

  announce "cordon ${node} (holds ${ns}/${name}'s primary ${cur})" \
           "delete pod ${ns}/${cur} — its local-path-retain PVC pins it to ${node}, so it cannot come back" \
           "wait up to ${INJECT_TIMEOUT}s for the roll's own detector to call it deadlocked" \
           "undo with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
  if [[ $DRY_RUN -eq 1 ]]; then ok "dry-run — nothing touched"; return 0; fi
  confirm

  "${KCTL[@]}" cordon "$node" || die "cordon failed for ${node}"
  "${KCTL[@]}" -n "$ns" delete pod "$cur" --wait=false >/dev/null ||
    { "${KCTL[@]}" uncordon "$node" || true; die "could not delete ${ns}/${cur} — node uncordoned, nothing injected"; }
  ok "deleted ${ns}/${cur}; waiting for CNPG to stall"

  local waited=0 d
  while [[ $waited -lt $INJECT_TIMEOUT ]]; do
    d="$(cnpg_deadlocked)"
    if [[ -n "$d" ]]; then
      hr; ok "deadlock reproduced after ${waited}s — <ns> <cluster> <target> <gone primary>:"
      printf '   %s\n' "$d"
      info "This is the state the roll unsticks after CNPG_UNSTICK_AFTER (${CNPG_UNSTICK_AFTER:-180}s)."
      info "Clean up with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  # An injection that quietly failed to inject would send someone off to debug a
  # detector against a healthy cluster. Fail, and print what the state really is.
  hr; cnpg_list | sed 's/^/   /' >&2 || true
  die "after ${INJECT_TIMEOUT}s the roll's detector still sees no deadlock (state above).
  ${node} is still cordoned — clean up with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
}

do_cleanup() {
  local cordoned
  cordoned="$(awk -F'\t' '$3 == "cordoned" { printf "%s ", $1 }' <<<"$NODES_TSV")"
  [[ -n "$cordoned" ]] || { ok "no node is cordoned — nothing to clean up"; return 0; }
  announce "uncordon: ${cordoned}" \
           "pods pinned to those nodes by a local PVC can then be rescheduled there"
  if [[ $DRY_RUN -eq 1 ]]; then ok "dry-run — nothing touched"; return 0; fi
  confirm
  local n
  for n in $cordoned; do
    "${KCTL[@]}" uncordon "$n" || warn "uncordon failed for ${n}"
  done
  ok "uncordoned: ${cordoned}"
  info "CNPG recovers on its own once the pod can come back; check with: $(basename "${BASH_SOURCE[0]}") status ${PROVIDER}"
}

# ==============================================================================
require_disposable_live_cluster
case "$CMD" in
  status)               do_status ;;
  resume)               do_resume ;;
  inject-cnpg-deadlock) do_inject ;;
  cleanup)              do_cleanup ;;
esac
