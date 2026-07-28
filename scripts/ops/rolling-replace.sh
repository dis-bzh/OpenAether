#!/usr/bin/env bash
# OpenAether — rolling node replacement (zero-downtime ForceNew apply)
#
# `instance_type` and the Talos image are ForceNew: a plain `tofu apply` replaces
# every node IN PARALLEL → the 3 control planes reboot at once → etcd loses
# quorum. This script does one node at a time: cordon+drain → targeted apply →
# wait for etcd/Longhorn → uncordon.
#
# Two non-obvious points:
#   * `-replace` on talos_machine_configuration_apply is ESSENTIAL — it never
#     references the instance ID, so a replaced VM yields no diff and would stay
#     in maintenance mode, unconfigured.
#   * The target list EXCLUDES the data-volume resources (they must survive) but
#     INCLUDES the attach/link ones (they point at the old instance ID).
#
# Order: workers first, then control planes strictly one at a time, gated on
# etcd back to 3/3. Stops on the first failed gate.
#
# ⚠️ Exercised live on Scaleway only (see deployment-test-matrix.md). On Proxmox
# the worker data disk is inline on the VM: replacing a worker WIPES it and
# Longhorn rebuilds from the surviving replicas — check they are healthy first.
#
# Usage: rolling-replace.sh <provider> [--workers-only|--cp-only] [--dry-run] [--yes]
#   Needs: tofu init, AWS_* creds, open Talos tunnels, ./talosconfig + ./kubeconfig.
#   rolling-replace.sh <provider> [--workers-only|--cp-only] [--dry-run] [--yes]
# ==============================================================================
set -euo pipefail

# --- args --------------------------------------------------------------------
PROVIDER="${1:-scaleway}"
shift || true
SCOPE="all"        # all | workers | cp
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --workers-only) SCOPE="workers" ;;
    --cp-only)      SCOPE="cp" ;;
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    *) echo "✗ unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Provider → module name in cluster/main.tf (junction modules, count-gated).
case "$PROVIDER" in
  scaleway) MOD="scw" ;;
  ovh)      MOD="ovh" ;;
  outscale) MOD="outscale" ;;
  proxmox)  MOD="proxmox" ;;
  *) echo "✗ unknown provider: $PROVIDER (expected scaleway|ovh|outscale|proxmox)" >&2; exit 2 ;;
esac
if [[ "$PROVIDER" != "scaleway" ]]; then
  echo "⚠ ${PROVIDER}: rolling-replace path is code-complete but has NEVER been exercised" >&2
  echo "  on a live cluster (deployment-test-matrix ⬜) — run --dry-run first and review targets." >&2
fi
if [[ "$PROVIDER" == "proxmox" ]]; then
  echo "⚠ proxmox: worker data disks are inline on the VM — replacing a worker WIPES its" >&2
  echo "  Longhorn disk (rebuild from surviving replicas). Check volume health/replicas first." >&2
fi

# --- config ------------------------------------------------------------------
TFVARS="envs/management-${PROVIDER}.tfvars"
TALOSCONFIG_FILE="${TALOSCONFIG:-./talosconfig}"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300s}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-600}"   # seconds
ETCD_TIMEOUT="${ETCD_TIMEOUT:-300}"               # seconds
LONGHORN_TIMEOUT="${LONGHORN_TIMEOUT:-600}"       # seconds
POLL=10                                           # seconds between health polls

export TALOSCONFIG="$TALOSCONFIG_FILE"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")

# --- logging -----------------------------------------------------------------
info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
hr()   { printf -- '─%.0s' {1..70}; printf '\n'; }

# --- preflight ---------------------------------------------------------------
for bin in tofu jq talosctl; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required"
done
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
[[ -f "$TFVARS" ]] || die "tfvars not found: $TFVARS (run from infrastructure/opentofu/cluster)"
[[ -f "$TALOSCONFIG_FILE" ]] || die "talosconfig not found: $TALOSCONFIG_FILE"
[[ -f "$KUBECONFIG_FILE"  ]] || die "kubeconfig not found: $KUBECONFIG_FILE"

OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
# Node identity prefix is "<cluster_name>-<environment>" (cluster/main.tf:249).
# Derive it from the tfvars (single source of truth) rather than guessing.
CN="$(grep -E '^[[:space:]]*cluster_name[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
ENVN="$(grep -E '^[[:space:]]*environment[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | sed 's/[[:space:]]*$//')"
[[ -n "$CN" && -n "$ENVN" ]] || die "could not read cluster_name/environment from $TFVARS"
NODE_PREFIX="${CN}-${ENVN}"

mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
[[ ${#CP_IPS[@]} -gt 0 ]] || die "no control_plane_private_ips in tofu output — is the infra deployed?"

info "Cluster: ${NODE_PREFIX} on ${PROVIDER}  (${#CP_IPS[@]} CP, ${#WK_IPS[@]} workers)"
info "Scope: ${SCOPE}   dry-run: $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"

# --- talos endpoint per node (matches talos-tunnels.sh: CP 50000+i, WK 50100+i) ---
# Talos node identity is the private IP; we reach its API via the localhost tunnel.
talos_ep() { # <type> <index>
  case "$1" in
    cp)     echo "127.0.0.1:$((50000 + $2))" ;;
    worker) echo "127.0.0.1:$((50100 + $2))" ;;
  esac
}

# ==============================================================================
# Health gates
# ==============================================================================

# Find a healthy CP endpoint OTHER than the one being replaced.
# Echoes "ep ip" for the first CP (index != exclude) whose etcd service is OK.
healthy_peer_cp() { # <exclude_index>
  local excl="$1" k ep ip
  for k in "${!CP_IPS[@]}"; do
    [[ "$k" == "$excl" ]] && continue
    ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
    if talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; then
      echo "$ep $ip"; return 0
    fi
  done
  return 1
}

# Remove a control-plane node's stale etcd membership from a healthy peer.
# REQUIRED before recreating a CP: tofu destroys the VM WITHOUT a graceful etcd
# leave, so the member lingers (dead peer). The fresh-disk node would then rejoin
# as a NEW member → N+1 members, quorum math broken, gate hangs. Talos auto-rejoins
# the recreated node, so we only need to evict the old member.
#
# `talosctl etcd remove-member` takes the hex MEMBER ID, not the node name. The
# `etcd members` table is: NODE  ID  HOSTNAME  PEER_URLS  CLIENT_URLS  LEARNER —
# so we resolve name→ID by matching HOSTNAME (col 3) and reading ID (col 2).
etcd_remove_member() { # <node_name> <exclude_index>
  local node="$1" excl="$2" peer ep ip mid
  peer="$(healthy_peer_cp "$excl")" || die "no healthy peer CP to evict etcd member ${node} — refusing to proceed (quorum risk)"
  read -r ep ip <<<"$peer"
  mid="$(talosctl -e "$ep" -n "$ip" etcd members 2>/dev/null | awk -v h="$node" '$3==h {print $2; exit}')"
  if [[ -z "$mid" ]]; then
    ok "etcd member ${node} already absent (nothing to evict)"; return 0
  fi
  info "Evicting stale etcd member ${node} (ID ${mid}) via cp-${excl}'s peer (${ip})…"
  talosctl -e "$ep" -n "$ip" etcd remove-member "$mid" 2>/dev/null \
    && ok "etcd member ${node} (${mid}) removed" \
    || die "etcd remove-member ${mid} failed — STOP (manual: talosctl -n <healthy-cp> etcd remove-member ${mid})"
}

# etcd must report all CP members present AND healthy before we touch the next CP.
# Queries each CP in turn until one answers — robust to the CP currently rebooting
# (talosctl -e <tunnel> connects, -n <real-ip> is the node identity apid validates).
# Each member row carries exactly one peer URL on :2380, so that count == members.
wait_etcd_healthy() { # <expected_members>
  local want="$1" deadline=$(( SECONDS + ETCD_TIMEOUT ))
  info "Waiting for etcd ${want}/${want} members healthy…"
  while (( SECONDS < deadline )); do
    local k ep ip n
    for k in "${!CP_IPS[@]}"; do
      ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
      n="$(talosctl -e "$ep" -n "$ip" etcd members 2>/dev/null | grep -cE ':2380' || true)"
      if [[ "$n" == "$want" ]] \
         && talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; then
        ok "etcd ${want}/${want} healthy (via cp-${k})"; return 0
      fi
    done
    sleep "$POLL"
  done
  return 1
}

wait_node_ready() { # <node_name>
  local node="$1" deadline=$(( SECONDS + NODE_READY_TIMEOUT ))
  info "Waiting for node ${node} Ready…"
  while (( SECONDS < deadline )); do
    if "${KCTL[@]}" get node "$node" >/dev/null 2>&1; then
      local st
      st="$("${KCTL[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      [[ "$st" == "True" ]] && { ok "node ${node} Ready"; return 0; }
    fi
    sleep "$POLL"
  done
  return 1
}

# No Longhorn volume may be stuck faulted; degraded is tolerated transiently but
# must clear before we proceed (rebuild finished).
wait_longhorn_healthy() {
  local deadline=$(( SECONDS + LONGHORN_TIMEOUT ))
  # Longhorn CRD absent (e.g. before storage layer) → nothing to gate on.
  "${KCTL[@]}" get crd volumes.longhorn.io >/dev/null 2>&1 || { ok "Longhorn not present — skipping volume gate"; return 0; }
  info "Waiting for Longhorn volumes to leave degraded/faulted…"
  while (( SECONDS < deadline )); do
    local faulted bad
    faulted="$("${KCTL[@]}" get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.robustness=="faulted")] | length' 2>/dev/null || echo 0)"
    bad="$("${KCTL[@]}" get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.robustness=="degraded")] | length' 2>/dev/null || echo 0)"
    [[ "$faulted" -gt 0 ]] && die "Longhorn has ${faulted} FAULTED volume(s) — aborting (manual recovery needed)"
    if [[ "$bad" == "0" ]]; then ok "Longhorn volumes healthy"; return 0; fi
    sleep "$POLL"
  done
  warn "Longhorn still has degraded volumes after ${LONGHORN_TIMEOUT}s"
  return 1
}

# ==============================================================================
# Per-node replacement
# ==============================================================================

# All state resources of THIS node under module.<mod>[0]: the VM/instance and its
# NIC/port (named exactly <tf_t>[i]) plus, for workers, the volume attach/link
# resources (named worker_data[i]) — but NOT the data volumes themselves, which
# must survive the replacement.
node_targets() { # <tf_t> <index>
  tofu state list 2>/dev/null | grep -F "module.${MOD}[0]." | awk -v t="$1" -v i="$2" '
    $0 ~ ("\\." t "\\[" i "\\]$") { print; next }
    t == "worker" && $0 ~ ("\\.worker_data\\[" i "\\]$") \
      && $0 !~ /(scaleway_block_volume|openstack_blockstorage_volume_v3|outscale_volume)\./ { print }
  '
}

replace_node() { # <type: cp|worker> <index>
  local t="$1" i="$2"
  local node_name node_ip ep cfg_addr tf_t
  if [[ "$t" == "cp" ]]; then
    node_name="${NODE_PREFIX}-cp-${i}"; node_ip="${CP_IPS[$i]}"; tf_t="control_plane"
  else
    node_name="${NODE_PREFIX}-worker-${i}"; node_ip="${WK_IPS[$i]}"; tf_t="worker"
  fi
  ep="$(talos_ep "$t" "$i")"
  cfg_addr="module.talos.talos_machine_configuration_apply.${tf_t}[${i}]"

  local -a targets=()
  local addr
  while IFS= read -r addr; do targets+=("-target=${addr}"); done < <(node_targets "$tf_t" "$i")
  [[ ${#targets[@]} -gt 0 ]] \
    || die "no state resources match module.${MOD}[0].*.${tf_t}[${i}] — wrong PROVIDER, or state not initialized?"

  hr
  info "Node ${node_name}  (ip ${node_ip}, talos ${ep})"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  would: kubectl cordon ${node_name}"
    echo "  would: kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT}"
    [[ $t == cp ]] && echo "  would: talosctl etcd remove-member ${node_name} (via a healthy peer CP)"
    echo "  would: tofu apply ${targets[*]} \\"
    echo "                    -replace='${cfg_addr}' \\"
    echo "                    -var-file='${TFVARS}' -var talos_bootstrap=true -auto-approve"
    echo "  would: wait Talos health @ ${ep}, node Ready, $( [[ $t == cp ]] && echo 'etcd 3/3, ' )Longhorn healthy"
    echo "  would: kubectl uncordon ${node_name}"
    return 0
  fi

  # 1. cordon + drain (evacuate workloads, trigger Longhorn rebuild / app failover)
  info "Cordon + drain ${node_name}…"
  "${KCTL[@]}" cordon "$node_name" || die "cordon failed for ${node_name}"
  if ! "${KCTL[@]}" drain "$node_name" \
        --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"; then
    warn "drain hit its timeout (${DRAIN_TIMEOUT}); some pods may be stuck (PDBs?)."
    [[ $ASSUME_YES -eq 1 ]] || { read -rp "Continue replacing ${node_name} anyway? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"; }
  fi

  # 1b. control plane: evict the stale etcd member BEFORE destroying the VM, while
  # the remaining peers still hold quorum. (tofu destroy = ungraceful leave.)
  if [[ "$t" == "cp" ]]; then
    etcd_remove_member "$node_name" "$i"
  fi

  # 2. targeted recreate of THIS node only + forced Talos config re-apply
  info "tofu apply (targeted) — recreate ${node_name} + reattach NIC/IP + re-apply Talos config…"
  info "targets: ${targets[*]#-target=}"
  tofu apply \
    "${targets[@]}" \
    -replace="$cfg_addr" \
    -var-file="$TFVARS" \
    -var talos_bootstrap=true \
    -auto-approve \
    || die "tofu apply failed for ${node_name} — cluster left with ${node_name} cordoned; investigate before retrying"

  # 3. Talos services up on the fresh VM (-e tunnel connects, -n real IP = identity)
  info "Waiting for Talos to come up on ${node_name} (${ep} → ${node_ip})…"
  local td=$(( SECONDS + NODE_READY_TIMEOUT ))
  until talosctl -e "$ep" -n "$node_ip" service kubelet 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; do
    (( SECONDS < td )) || die "Talos kubelet not healthy on ${node_name} after ${NODE_READY_TIMEOUT}s"
    sleep "$POLL"
  done
  ok "Talos services up on ${node_name}"

  # 4. node Ready in k8s
  wait_node_ready "$node_name" || die "node ${node_name} not Ready in time — STOP"

  # 5. for control planes: etcd must be back to full membership before the next CP
  if [[ "$t" == "cp" ]]; then
    wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd did not return to ${#CP_IPS[@]}/${#CP_IPS[@]} healthy — STOP (do NOT replace another CP)"
  fi

  # 6. Longhorn rebuild complete (no degraded/faulted)
  wait_longhorn_healthy || die "Longhorn not healthy after replacing ${node_name} — STOP"

  # 7. back into rotation
  "${KCTL[@]}" uncordon "$node_name" || warn "uncordon failed for ${node_name} (re-run manually)"
  ok "Node ${node_name} replaced and back in rotation"
}

# ==============================================================================
# Main
# ==============================================================================
# Global pre-check: cluster must be healthy BEFORE we start pulling nodes.
hr
info "Pre-flight health check…"
if [[ $DRY_RUN -eq 0 ]]; then
  wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd is not ${#CP_IPS[@]}/${#CP_IPS[@]} healthy — refusing to start a rolling replace on an unhealthy cluster"
  "${KCTL[@]}" get nodes >/dev/null 2>&1 || die "kubectl cannot reach the API via ${KUBECONFIG_FILE}"
  not_ready="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{c++} END{print c+0}')"
  [[ "$not_ready" == "0" ]] || die "${not_ready} node(s) not Ready — stabilize the cluster first"
  ok "Cluster healthy — proceeding"
else
  ok "dry-run — skipping live pre-flight"
fi

if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  hr
  warn "This will DESTROY and recreate node instances one at a time on ${PROVIDER}."
  warn "System disks are wiped (OS only); Longhorn data disks are preserved."
  read -rp "Proceed with rolling replacement? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
fi

# Workers first (heavy stateful load), then control planes (etcd-gated).
if [[ "$SCOPE" == "all" || "$SCOPE" == "workers" ]]; then
  for j in "${!WK_IPS[@]}"; do replace_node worker "$j"; done
fi
if [[ "$SCOPE" == "all" || "$SCOPE" == "cp" ]]; then
  for j in "${!CP_IPS[@]}"; do replace_node cp "$j"; done
fi

hr
if [[ $DRY_RUN -eq 1 ]]; then
  ok "dry-run complete — no changes made"
else
  ok "Rolling replacement complete. Run a state backup:  scripts/ops/backup-state.sh"
fi
