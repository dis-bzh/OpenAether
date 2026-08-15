#!/usr/bin/env bash
# OpenAether — rolling node replacement (zero-downtime ForceNew apply)
#
# `instance_type` and the Talos image change what a node must boot, and a plain
# `tofu apply` acts on every node AT ONCE → the 3 control planes go together →
# etcd loses quorum. This script does one node at a time: cordon+drain →
# targeted apply → wait for etcd/Longhorn → uncordon.
#
# Each node takes TWO applies: the instance first, then its Talos config once the
# new VM exists. The graph does not order those — modules/talos reads each node's
# address from IPAM, not from the instance — so in a single apply tofu configured
# the OLD VM a second before destroying it, and the replacement came up in
# maintenance mode. Every "kubelet not healthy after 600s" traced back to that.
#
# Before each node it PLANS and counts what would be destroyed, and refuses if
# that exceeds the resources it targets. "One node at a time" used to be an
# intention nothing checked: on 2026-08-12 one extra -target pulled a whole
# provider module in and a per-node apply replaced all three control planes
# together. The count is now the check.
#
# Four non-obvious points:
#   * `-replace` on the INSTANCE is ESSENTIAL, and `-target` is not enough:
#     -target narrows the plan, it forces nothing. Whether an image change is
#     ForceNew is provider-specific — true on Scaleway, false on OpenStack,
#     where image_id updates in place. Without the explicit replace, a Talos
#     version bump on OVH rewrote the attribute and left the VM booted on the
#     old image: state said v1.13.8, every node reported v1.13.7 (2026-08-12).
#   * `-replace` on talos_machine_configuration_apply is ESSENTIAL — it never
#     references the instance ID, so a replaced VM yields no diff and would stay
#     in maintenance mode, unconfigured.
#   * The target list EXCLUDES the data-volume resources (they must survive) but
#     INCLUDES the attach/link ones (they point at the old instance ID).
#
# Order: workers first, then control planes strictly one at a time, gated on
# etcd back to 3/3. Stops on the first failed gate.
#
# ⚠️ Exercised live on Scaleway, OVH and Outscale (--upgrade on all three;
# replacement only on Scaleway). Never on Proxmox. On Proxmox
# the worker data disk is inline on the VM: replacing a worker WIPES it and
# Longhorn rebuilds from the surviving replicas — check they are healthy first.
#
# Usage: rolling-replace.sh <provider> [--workers-only|--cp-only] [--upgrade]
#                          [--dry-run] [--yes]
#   --upgrade: `talosctl upgrade` in place (version changes) instead of
#   replacing the VM. Reads the target from talos_version in the tfvars.
#   Needs: tofu init, AWS_* creds, open Talos tunnels, ./talosconfig + ./kubeconfig.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- args --------------------------------------------------------------------
PROVIDER="${1:-scaleway}"
shift || true
SCOPE="all"        # all | workers | cp
DRY_RUN=0
ASSUME_YES=0
UPGRADE=0         # --upgrade: in-place `talosctl upgrade`, no VM replacement
for arg in "$@"; do
  case "$arg" in
    --workers-only) SCOPE="workers" ;;
    --cp-only)      SCOPE="cp" ;;
    --dry-run)      DRY_RUN=1 ;;
    --upgrade)      UPGRADE=1 ;;
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
# --upgrade has been exercised live on all three clouds (2026-08-13); the
# REPLACEMENT path (no --upgrade) only ever on Scaleway. Warn about the one that
# is actually unproven, not about the whole script — the blanket warning
# contradicted this file's own header and taught readers to ignore it.
if [[ "$PROVIDER" != "scaleway" && "$UPGRADE" -eq 0 ]]; then
  echo "⚠ ${PROVIDER}: the node-REPLACEMENT path has never been exercised on a live" >&2
  echo "  cluster (only --upgrade has) — run --dry-run first and review the targets." >&2
fi
if [[ "$PROVIDER" == "proxmox" ]]; then
  echo "⚠ proxmox: worker data disks are inline on the VM — replacing a worker WIPES its" >&2
  echo "  Longhorn disk (rebuild from surviving replicas). Check volume health/replicas first." >&2
fi

# --- config ------------------------------------------------------------------
TFVARS="envs/management-${PROVIDER}.tfvars"
TALOSCONFIG_FILE="${TALOSCONFIG:-./talosconfig}"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
# 300s was not enough for a database switchover, and the run continued anyway.
# A switchover is a legitimate reason to wait; a drain that never finishes is now
# fatal, so the budget has to be generous enough to tell the two apart.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-900s}"
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

# --upgrade needs the installer image for the version this tree declares. Read it
# from the same tfvars everything else comes from; TALOS_IMAGE overrides for a
# custom schematic (Image Factory) whose id is not derivable from a version.
if [[ $UPGRADE -eq 1 && -z "${TALOS_IMAGE:-}" ]]; then
  TV="$(grep -E '^[[:space:]]*talos_version[[:space:]]*=' "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')"
  [[ -n "$TV" ]] || die "--upgrade: no talos_version in ${TFVARS}. Pin it, or pass TALOS_IMAGE=ghcr.io/siderolabs/installer:vX.Y.Z"
  TALOS_IMAGE="ghcr.io/siderolabs/installer:${TV}"
fi

mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
[[ ${#CP_IPS[@]} -gt 0 ]] || die "no control_plane_private_ips in tofu output — is the infra deployed?"

info "Cluster: ${NODE_PREFIX} on ${PROVIDER}  (${#CP_IPS[@]} CP, ${#WK_IPS[@]} workers)"
info "Scope: ${SCOPE}   dry-run: $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"

# --- talos endpoint per node (matches talos-tunnels.sh: CP 50000+i, WK 50100+i,
# both shifted by TALOS_TUNNEL_OFFSET) ---
# Talos node identity is the private IP; we reach its API via the localhost tunnel.
TUNNEL_OFFSET="$(oa_tunnel_offset)" || exit 1
talos_ep() { # <type> <index>
  case "$1" in
    cp)     echo "127.0.0.1:$((50000 + TUNNEL_OFFSET + $2))" ;;
    worker) echo "127.0.0.1:$((50100 + TUNNEL_OFFSET + $2))" ;;
  esac
}

# Kubernetes node name for a private IP. Node NAMES are provider-specific; the
# InternalIP is not, and it is what the tofu state gives us.
k8s_node_for_ip() { # <private-ip>
  local name
  name="$("${KCTL[@]}" get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{range .status.addresses[?(@.type=='InternalIP')]}{.address}{end}{'\n'}{end}" 2>/dev/null \
          | awk -v ip="$1" '$2 == ip { print $1; exit }')"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
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
# Cordon + drain, tolerant of a drain that cannot finish. A PDB with zero allowed
# disruptions (a single-replica workload declaring minAvailable: 1) makes a node
# permanently undrainable, so a drain that must succeed can never roll such a
# cluster. We report it and let the operator decide; talosctl's own drain does
# not, which is why --upgrade runs it with --drain=false and calls this instead.
# CNPG guards its primary with a PodDisruptionBudget that forbids eviction until
# a switchover has happened, and a plain `kubectl drain` does not trigger one —
# so the drain simply times out. Telling the operator a node maintenance is in
# progress is the documented way to say "you may move these": it relaxes the
# budget and lets the instance be recreated, reusing its PVC.
#
# Without this the roll drained for five minutes, gave up, and rebooted the node
# under a live primary — three times in one run on 2026-08-14, which left
# `zitadel-db` stuck in "Switchover in progress" and `grafana-db` with no active
# instance, and took eight Kustomizations down behind them.
# MEASURED on Scaleway 2026-08-15, because "necessary and not sufficient" was
# still not saying WHICH budget refused. With the maintenance window ON, CNPG
# deletes the replica budget and KEEPS `<cluster>-primary` at
# disruptionsAllowed=0 / currentHealthy=1 / expectedPods=1. The primary is
# therefore unevictable on any node, by design, for as long as it is primary —
# which is the 900s drain, exactly.
#
# `spec.enablePDB: false` deletes BOTH, primary included; the operator's own
# webhook recommends it over the maintenance window on every patch. Turning it
# off for the roll lets the drain evict the primary and CNPG fail over to a
# replica — an unplanned failover, which is what a planned node reboot is going
# to cause anyway a few seconds later.
#
# The maintenance window stays alongside it: it is what tells the operator to
# reuse the PVC rather than reprovision the instance elsewhere, which on
# node-local storage it could not do.
# Flux owns the CNPG Cluster objects and reconciles them every 10 minutes, which
# is shorter than a roll: measured on Scaleway 2026-08-15, the budgets were back
# and the drain blocked again three nodes in, because git says enablePDB is on
# and git wins. Suspend the Kustomization that owns them for the duration and
# resume it on the way out. The owner comes from the objects' own Flux labels,
# not a hardcoded name, so a rename does not silently turn this into a no-op.
cnpg_flux_suspend() { # <true|false>
  local suspend="$1" ns name
  { "${KCTL[@]}" get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/namespace}{" "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}' 2>/dev/null || true; } |
    sort -u |
    while read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      if "${KCTL[@]}" -n "$ns" patch kustomizations.kustomize.toolkit.fluxcd.io "$name" \
        --type merge -p "{\"spec\":{\"suspend\":${suspend}}}" >/dev/null 2>&1; then
        info "Flux ${ns}/${name}: suspend=${suspend}"
      else
        warn "could not set suspend=${suspend} on Kustomization ${ns}/${name}"
      fi
    done
}

cnpg_maintenance() { # <true|false>
  local on="$1" ns name pdb
  # enablePDB is the INVERSE of "maintenance in progress": budgets off while we
  # roll, back on when we are done.
  [[ "$on" == "true" ]] && pdb=false || pdb=true
  # Suspend BEFORE patching, so there is no window for Flux to undo it.
  [[ "$on" == "true" ]] && cnpg_flux_suspend true
  # `|| true`: a cluster without the CNPG CRD is a normal cluster, and under
  # `pipefail` the failing get would otherwise kill the whole roll.
  { "${KCTL[@]}" get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true; } |
    while read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      if "${KCTL[@]}" -n "$ns" patch clusters.postgresql.cnpg.io "$name" --type merge \
        -p "{\"spec\":{\"enablePDB\":${pdb},\"nodeMaintenanceWindow\":{\"inProgress\":${on},\"reusePVC\":true}}}" >/dev/null 2>&1; then
        info "CNPG ${ns}/${name}: enablePDB=${pdb}, nodeMaintenanceWindow.inProgress=${on}"
      else
        warn "could not set enablePDB=${pdb} / nodeMaintenanceWindow=${on} on ${ns}/${name}"
      fi
    done
  # Resume AFTER restoring, so Flux finds the objects already back where git
  # wants them. Leaving a Kustomization suspended is the failure mode this
  # function must not have — staging-verify.sh fails the run if one is.
  [[ "$on" == "true" ]] || cnpg_flux_suspend false

  # ⚠️ The patch returning 0 is not the setting taking effect. On OVH
  # 2026-08-15 both clusters logged enablePDB=false and their budgets were still
  # there ten minutes later, carrying their deploy-time creation timestamp — so
  # they had never been deleted, the roll drained on an assumption that had
  # silently failed, and it cost 900s of eviction retries to find out. The same
  # patch applied by hand afterwards removed them in under thirty seconds, so the
  # mechanism is right and only the confirmation was missing.
  #
  # Confirm on the way IN only: on the way out the budgets coming back is Flux's
  # and the operator's business, and staging-verify.sh is what checks the end
  # state.
  [[ "$on" == "true" ]] || return 0
  local waited=0 left
  while [[ $waited -lt 120 ]]; do
    left="$("${KCTL[@]}" get pdb -A -l cnpg.io/cluster \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null || true)"
    [[ -z "$left" ]] && { ok "CNPG budgets are gone — the node can lose a primary"; return 0; }
    sleep 5; waited=$((waited + 5))
  done
  die "CNPG budgets survived enablePDB=false after 120s: ${left}
  The patch reported success and the operator did not act on it. Draining now
  would retry evictions for ${DRAIN_TIMEOUT} and fail — see docs/upgrade.md
  § 'What actually blocks a drain'. Check the operator in cnpg-system."
}

# The CNPG primary used to be switched off the node here, with `kubectl cnpg
# promote`. Removed on 2026-08-15, for two measured reasons:
#
#   * it never ran. Both of its readbacks used `kubectl get cluster`, and on a
#     cluster carrying CAPI that name resolves to clusters.cluster.x-k8s.io, not
#     clusters.postgresql.cnpg.io. The confirmation compared an empty string to
#     the old primary, found them different and declared the primary moved
#     within a second; the "wait until the cluster is whole again" loop could
#     never see a number and always ran its full 600s. The roll then drained a
#     node whose primary had not moved.
#   * the promote itself does nothing here. `kubectl-cnpg promote` (plugin
#     1.23.6, operator 1.23.1) exits 0 and prints "will be promoted", and
#     `status.targetPrimary` does not change. Unexplained; backlog.
#
# `spec.enablePDB: false` in cnpg_maintenance above removes the budget that made
# the primary unevictable, which is what the switchover was for. Nothing here
# needs the plugin any more.

# Wait until every CNPG cluster is whole again before touching the next node.
#
# With the budgets off for the roll, a drain evicts a primary and CNPG fails over
# — normal, and finished in a minute when it is left alone. Arriving at the next
# node before it finishes is what is not: on 2026-08-15 the roll drained a second
# worker while zitadel-db was still electing, and the cluster deadlocked with the
# demoted primary waiting for a switchover and the target replica waiting for WAL
# only a running primary would produce. It cost a hand-deleted pod, twice.
#
# The qualified resource name is not optional — see the note above.
CNPG_TIMEOUT="${CNPG_TIMEOUT:-600}"   # seconds
wait_cnpg_whole() {
  local waited=0 pending ns name inst ready
  while [[ $waited -lt $CNPG_TIMEOUT ]]; do
    pending=""
    while read -r ns name inst ready; do
      [[ -n "$ns" && -n "$name" ]] || continue
      # A status that has not been populated must not read as "whole": require
      # real numbers, the way the 0/0 check that used to pass here did not.
      [[ "$inst" =~ ^[1-9][0-9]*$ && "$ready" == "$inst" ]] || pending+="${ns}/${name}(${ready:-?}/${inst:-?}) "
    done < <("${KCTL[@]}" get clusters.postgresql.cnpg.io -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.instances}{" "}{.status.readyInstances}{"\n"}{end}' 2>/dev/null || true)
    [[ -z "$pending" ]] && { [[ $waited -gt 0 ]] && ok "every CNPG cluster is whole again"; return 0; }
    [[ $waited -eq 0 ]] && info "Waiting for CNPG to finish electing: ${pending}"
    sleep 10; waited=$((waited + 10))
  done
  warn "after ${CNPG_TIMEOUT}s these CNPG clusters are still not whole: ${pending}"
  warn "  draining the next node now is what deadlocked one on 2026-08-15 —"
  warn "  see docs/upgrade.md § 'A database left \"Failing over\" after the roll'."
}

# Wait until the cluster says it can afford to lose a pod on this node.
#
# Between nodes the roll gates on etcd and Longhorn and on NOTHING else, so it
# arrived at the next node while the previous one's quorum workloads were still
# rejoining — and their budgets correctly refused the eviction. Three runs, three
# different pods, one shape: CNPG replicas and kube-state-metrics (run 8),
# `openbao-1` on a raft budget wanting 2 of 3 (run 9), with no CNPG primary
# involved at all. Fixing them one at a time was chasing symptoms.
#
# `disruptionsAllowed` is the cluster stating the thing directly. Only budgets
# that actually cover a pod ON THIS NODE matter: one stuck elsewhere is not our
# business and waiting on it would be a hang with no cause.
PDB_TIMEOUT="${PDB_TIMEOUT:-600}"   # seconds
wait_pdb_headroom() { # <node_name>
  local node="$1" waited=0 blocked ns name sel
  info "Waiting for every budget covering ${node} to allow a disruption…"
  while [[ $waited -lt $PDB_TIMEOUT ]]; do
    blocked=""
    while IFS=$'\t' read -r ns name sel; do
      [[ -n "$ns" && -n "$name" ]] || continue
      # Empty means matchLabels was absent — a matchExpressions-only budget,
      # which none of ours uses. Skip rather than guess; the drain is the judge.
      [[ -n "$sel" ]] || continue
      if [[ -n "$("${KCTL[@]}" -n "$ns" get pods -l "$sel" \
            --field-selector "spec.nodeName=${node}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
        blocked+="${ns}/${name} "
      fi
      # `currentHealthy < expectedPods` is the whole discriminator, measured on a
      # live cluster 2026-08-14. Some budgets sit at zero BY DESIGN and waiting on
      # them never ends: a CNPG `*-primary` guards the one pod that must not be
      # evicted, and Longhorn mints one `instance-manager-*` per node with
      # minAvailable 1. Those read 1/1/1 — as healthy as they will ever be.
      # The ones worth waiting for read short: openbao 2 of 3, grafana 0 of 2,
      # vmselect 1 of 2 — pods still coming back from the node we just rolled.
    done < <({ "${KCTL[@]}" get pdb -A -o json 2>/dev/null || echo '{"items":[]}'; } |
      jq -r '.items[]
             | select((.status.disruptionsAllowed // 0) == 0)
             | select((.status.currentHealthy // 0) < (.status.expectedPods // 0))
             | [ .metadata.namespace, .metadata.name,
                 ((.spec.selector.matchLabels // {}) | to_entries
                  | map("\(.key)=\(.value)") | join(",")) ] | @tsv')
    if [[ -z "$blocked" ]]; then
      ok "every budget covering ${node} allows a disruption"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  # Fatal, unattended. This used to warn and drain anyway, on the reasoning that
  # the drain names the pods. It does — after another ${DRAIN_TIMEOUT}. On OVH
  # 2026-08-15 that meant 600s of "these budgets allow nothing" followed by 900s
  # of eviction retries against the same budgets, and the same answer at the end.
  # Every budget this gate waits on reads currentHealthy < expectedPods, so a pod
  # is MISSING: draining cannot supply it, and time cannot either.
  warn "after ${PDB_TIMEOUT}s these budgets still allow nothing on ${node}: ${blocked}"
  if [[ $ASSUME_YES -eq 1 ]]; then
    die "refusing to drain ${node} into budgets that already said no.
  Each one above is short of a pod (currentHealthy < expectedPods), so the drain
  would retry evictions for ${DRAIN_TIMEOUT} and reach the same conclusion.
  Fix what is missing, then re-run — nodes already upgraded are skipped."
  fi
  read -rp "Drain ${node} anyway? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
}

cordon_drain() { # <node_name>
  local node="$1"
  wait_cnpg_whole
  wait_pdb_headroom "$node"
  info "Cordon + drain ${node}…"
  "${KCTL[@]}" cordon "$node" || die "cordon failed for ${node}"
  if ! "${KCTL[@]}" drain "$node" \
        --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"; then
    warn "drain hit its timeout (${DRAIN_TIMEOUT}); some pods may be stuck (PDBs?)."
    # Unattended, this used to answer its own question and carry on. Rebooting a
    # node whose pods REFUSED to move is how a database gets cut off mid-write;
    # a half-rolled cluster is recoverable (this script skips nodes already on
    # the target version), a corrupted one is not. Fail, and name what blocked.
    if [[ $ASSUME_YES -eq 1 ]]; then
      "${KCTL[@]}" get pods --field-selector "spec.nodeName=${node}" -A \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | head -20 >&2 || true
      # The two causes seen for real, in the order worth checking. Capacity is
      # first because it is the one nothing else reports: on OVH 2026-08-15 the
      # three workers sat at 78/99/100% of CPU requests, so an evicted pod had
      # nowhere to go, its budget never recovered, and the drain waited out its
      # full 900s with no eviction error to show for it.
      "${KCTL[@]}" describe nodes -l '!node-role.kubernetes.io/control-plane' 2>/dev/null |
        grep -E "^Name:|^  cpu " >&2 || true
      die "${node} could not be drained within ${DRAIN_TIMEOUT} — refusing to reboot it under workloads that would not move.
  1. Capacity: the CPU requests above are per worker. If the others are near
     100%, the evicted pods cannot be rescheduled, so their budgets never
     recover. A rolling upgrade needs one node's worth of spare capacity.
  2. A budget that can never allow a disruption — see docs/upgrade.md
     § 'What actually blocks a drain, and the two gates that clear it'.
  Then re-run this same command: nodes already on the target version are skipped."
    fi
    read -rp "Continue with ${node} anyway? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
  fi
}

etcd_remove_member() { # <node_name> <node_ip> <exclude_index>
  local node="$1" node_ip="$2" excl="$3" peer ep ip mid
  peer="$(healthy_peer_cp "$excl")" || die "no healthy peer CP to evict etcd member ${node} — refusing to proceed (quorum risk)"
  read -r ep ip <<<"$peer"
  # Match the peer URL first, the hostname only as a fallback. An etcd member
  # keeps the name it joined under, so a node renamed since does not match by
  # name — and the lookup would report "already absent" for a member that is
  # still there, leaving it to be destroyed without ever being evicted.
  mid="$(talosctl -e "$ep" -n "$ip" etcd members 2>/dev/null \
         | awk -v mip="$node_ip" -v h="$node" \
               'index($4, "//" mip ":") > 0 || $3 == h {print $2; exit}')"
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
    node_ip="${CP_IPS[$i]}"; tf_t="control_plane"
  else
    node_ip="${WK_IPS[$i]}"; tf_t="worker"
  fi
  # Ask the cluster what this node is called instead of assuming the naming
  # convention. Scaleway and OVH get their hostname from the machine config
  # (<cluster>-<env>-cp-N); on Outscale Talos keeps the platform hostname, so
  # the nodes are ip-10-0-0-53 and every `kubectl cordon` here failed on "node
  # not found" — the dry-run printed the invented names and looked fine.
  # The private IP is the one identity all providers agree on.
  node_name="$(k8s_node_for_ip "$node_ip")" \
    || die "no Kubernetes node has internal IP ${node_ip} — is the cluster the one this state describes?"
  ep="$(talos_ep "$t" "$i")"
  cfg_addr="module.talos.talos_machine_configuration_apply.${tf_t}[${i}]"

  local -a targets=()
  local addr
  while IFS= read -r addr; do targets+=("-target=${addr}"); done < <(node_targets "$tf_t" "$i")
  [[ ${#targets[@]} -gt 0 ]] \
    || die "no state resources match module.${MOD}[0].*.${tf_t}[${i}] — wrong PROVIDER, or state not initialized?"

  # -target only NARROWS the plan; it does not force anything to be replaced.
  # The header of this script assumes a Talos image change is ForceNew, which is
  # true on Scaleway and false on OpenStack: there image_id updates in place, so
  # a version bump rewrote the attribute and left the VM booted on the old image
  # — state claiming v1.13.8 while every node reported v1.13.7 (2026-08-12).
  # Name the instance and replace it explicitly. NOT the port: recreating that
  # would hand the node a new private IP, which is its identity.
  local inst_addr
  inst_addr="$(printf '%s\n' "${targets[@]#-target=}" | grep -E '\.(scaleway_instance_server|openstack_compute_instance_v2|outscale_vm|proxmox_virtual_environment_vm)\.' | head -1)"
  [[ -n "$inst_addr" ]] \
    || die "no compute instance among the targets for ${node_name} — new provider whose instance resource this script does not know?"

  # The machine config lives under module.talos, and node_targets only collects
  # module.<provider>[0].* — so -target excluded it and the -replace naming it
  # below was silently dropped: tofu said "some changes requested in the
  # configuration may have been ignored" and carried on, the fresh VM booted into
  # maintenance mode, and the health gate waited 600s for a kubelet that was
  # never coming. Seen identically on OVH and Scaleway, 2026-08-12.
  #
  # Safe to target only because cluster/main.tf no longer gives module.talos a
  # module-level depends_on over the provider modules; with it, this single line
  # pulled every instance into the plan. Check the blast radius with --dry-run
  # and a plan before trusting it on a cluster you care about.
  targets+=("-target=${cfg_addr}")

  # And the port-ready guard the config apply depends on. Its triggers_replace is
  # the node ENDPOINT, which is unchanged by a replacement (same private IP), so
  # it is never re-created on its own — and being in module.talos it was outside
  # -target too. Without it the config apply fired against a node that had not
  # finished booting and reported "Creation complete after 0s" having done
  # nothing; the health gate then waited 600s for a kubelet that never started.
  # Absent from state when skip_port_ready_wait is set, hence the lookup.
  local guard_addr=""
  if tofu state list 2>/dev/null | grep -qxF "module.talos.terraform_data.talos_port_ready_${tf_t}[${i}]"; then
    guard_addr="module.talos.terraform_data.talos_port_ready_${tf_t}[${i}]"
    targets+=("-target=${guard_addr}")
  fi

  hr
  info "Node ${node_name}  (ip ${node_ip}, talos ${ep})"

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $UPGRADE -eq 1 ]]; then
      echo "  would: talosctl upgrade -e ${ep} -n ${node_ip} --image ${TALOS_IMAGE} --wait"
      echo "         (Talos cordons and drains the node itself, and refuses a CP that would cost etcd its quorum)"
      echo "  would: wait Talos health @ ${ep}, node Ready, $( [[ $t == cp ]] && echo 'etcd 3/3, ' )Longhorn healthy"
      return 0
    fi
    echo "  would: kubectl cordon ${node_name}"
    echo "  would: kubectl drain ${node_name} --ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT}"
    [[ $t == cp ]] && echo "  would: talosctl etcd remove-member ${node_name} (via a healthy peer CP)"
    echo "  would: tofu apply ${targets[*]} \\"
    echo "                    -replace='${inst_addr}' -replace='${cfg_addr}'${guard_addr:+ -replace=\'${guard_addr}\'} \\"
    echo "                    -var-file='${TFVARS}' -var talos_bootstrap=true -auto-approve"
    echo "  would: wait Talos health @ ${ep}, node Ready, $( [[ $t == cp ]] && echo 'etcd 3/3, ' )Longhorn healthy"
    echo "  would: kubectl uncordon ${node_name}"
    return 0
  fi

  # ── in-place upgrade: what Talos actually supports ──────────────────────────
  # `talosctl upgrade` writes the new system partition and reboots into it. The
  # node keeps its identity, its disk and its etcd membership, so none of the
  # replacement machinery below applies: no config to re-apply, no maintenance
  # mode, no stale etcd member to evict, and no orphan Kubernetes node object
  # from a kubelet that registered under a temporary hostname.
  #
  # Talos cordons and drains the node itself (--drain, on by default) and
  # refuses to upgrade a control plane if that would cost etcd its quorum. The
  # gates further down still run: they are ours to keep, and they are what makes
  # this one node at a time.
  if [[ $UPGRADE -eq 1 ]]; then
    # Re-runnable: a node already on the target version is left alone. Without
    # this, resuming an interrupted roll reboots the nodes it already did.
    local running
    running="$(talosctl version -e "$ep" -n "$node_ip" --short 2>/dev/null \
               | awk '/Server/{f=1} f && /Tag:/{print $2; exit}')"
    if [[ "$running" == "${TALOS_IMAGE##*:}" ]]; then
      ok "${node_name} already runs ${running} — skipping"
      return 0
    fi
    # The endpoint must be a CONTROL PLANE, even when the target is a worker.
    # talosctl fetches a kubeconfig from the endpoint to drain the node, and a
    # worker answers "kubeconfig is only available on control plane nodes" — so
    # the install succeeds and the command still exits non-zero. -n keeps naming
    # the node to act on; apid proxies.
    local up_ep="$ep"
    if [[ "$t" != "cp" ]]; then
      local cp_peer
      cp_peer="$(healthy_peer_cp -1)" || die "no healthy control plane to drive the upgrade of ${node_name}"
      read -r up_ep _ <<<"$cp_peer"
    fi
    cordon_drain "$node_name"
    info "talosctl upgrade ${node_name} ${running:-?} → ${TALOS_IMAGE}"
    # --drain=false: we just drained, tolerantly. Talos's own drain is all-or-
    # nothing and dies on the first PDB that forbids eviction.
    talosctl upgrade -e "$up_ep" -n "$node_ip" --image "$TALOS_IMAGE" --wait --drain=false \
      || die "upgrade failed on ${node_name} — the node kept its disk and membership; investigate before retrying"
    ok "${node_name} upgraded, waiting for it to come back"
  else

  # 1. cordon + drain (evacuate workloads, trigger Longhorn rebuild / app failover)
  cordon_drain "$node_name"

  # 1b. control plane: evict the stale etcd member BEFORE destroying the VM, while
  # the remaining peers still hold quorum. (tofu destroy = ungraceful leave.)
  if [[ "$t" == "cp" ]]; then
    etcd_remove_member "$node_name" "$node_ip" "$i"
  fi

  # 2. Count the blast radius BEFORE applying. "One node at a time" was an
  # intention this script never checked: on 2026-08-12 a single extra -target
  # pulled the whole provider module into the plan and one "per-node" apply
  # replaced all three control planes together, taking etcd down. A targeted
  # plan must not destroy more than the resources it targets.
  info "Planning ${node_name} and counting what it would destroy…"
  local doomed
  doomed="$(tofu plan "${targets[@]}" -replace="$inst_addr" -replace="$cfg_addr" \
              ${guard_addr:+-replace="$guard_addr"} \
              -var-file="$TFVARS" -var talos_bootstrap=true -no-color 2>/dev/null \
            | sed -nE 's/^Plan: [0-9]+ to add, [0-9]+ to change, ([0-9]+) to destroy\./\1/p' | tail -1)"
  [[ -n "$doomed" ]] || die "could not read a plan for ${node_name} — refusing to apply blind"
  if (( doomed > ${#targets[@]} )); then
    die "plan destroys ${doomed} resources for ONE node (it targets ${#targets[@]}) — refusing.
  Something outside this node is being pulled in; a module-level depends_on has
  done exactly that before. Inspect with:
    tofu plan ${targets[*]} -replace='${inst_addr}' -replace='${cfg_addr}' -var-file='${TFVARS}' -var talos_bootstrap=true"
  fi
  ok "plan destroys ${doomed} resource(s), targets ${#targets[@]} — proceeding"

  # 3. TWO applies, and the split is the whole point.
  #
  # modules/talos takes each node's address from the provider module's IPAM
  # resource, never from its instance, so nothing in the graph says "configure
  # the node after you have rebuilt it". In one apply tofu is free to order it
  # the other way round, and it does: observed 2026-08-13, the config applied to
  # the OLD VM one second before that VM was destroyed, and the replacement then
  # booted into maintenance mode with no config at all — which is what every
  # "kubelet not healthy after 600s" of the last two days actually was.
  #
  # The ordering has to come from here. First the instance, alone. Then the
  # guard and the config, against a node that now exists.
  local -a infra_targets=()
  local t
  for t in "${targets[@]}"; do
    [[ "$t" == "-target=${cfg_addr}" || "$t" == "-target=${guard_addr}" ]] || infra_targets+=("$t")
  done

  info "tofu apply 1/2 — recreate ${node_name} (instance, NIC/IP)…"
  info "targets: ${infra_targets[*]#-target=}"
  tofu apply \
    "${infra_targets[@]}" \
    -replace="$inst_addr" \
    -var-file="$TFVARS" \
    -var talos_bootstrap=true \
    -auto-approve \
    || die "tofu apply (instance) failed for ${node_name} — cluster left with ${node_name} cordoned; investigate before retrying"

  info "tofu apply 2/2 — wait for the new node, then apply its Talos config…"
  tofu apply \
    -target="$cfg_addr" ${guard_addr:+-target="$guard_addr"} \
    -replace="$cfg_addr" ${guard_addr:+-replace="$guard_addr"} \
    -var-file="$TFVARS" \
    -var talos_bootstrap=true \
    -auto-approve \
    || die "tofu apply (config) failed for ${node_name} — the VM exists but is unconfigured (maintenance mode); re-run to resume"

  fi  # end of the replacement path

  # 4. Talos services up on the fresh VM (-e tunnel connects, -n real IP = identity)
  info "Waiting for Talos to come up on ${node_name} (${ep} → ${node_ip})…"
  local td=$(( SECONDS + NODE_READY_TIMEOUT ))
  until talosctl -e "$ep" -n "$node_ip" service kubelet 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; do
    (( SECONDS < td )) || die "Talos kubelet not healthy on ${node_name} after ${NODE_READY_TIMEOUT}s"
    sleep "$POLL"
  done
  ok "Talos services up on ${node_name}"

  # 5. node Ready in k8s
  wait_node_ready "$node_name" || die "node ${node_name} not Ready in time — STOP"

  # 6. for control planes: etcd must be back to full membership before the next CP
  if [[ "$t" == "cp" ]]; then
    wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd did not return to ${#CP_IPS[@]}/${#CP_IPS[@]} healthy — STOP (do NOT replace another CP)"
  fi

  # 7. Longhorn rebuild complete (no degraded/faulted)
  wait_longhorn_healthy || die "Longhorn not healthy after replacing ${node_name} — STOP"

  # 8. back into rotation
  "${KCTL[@]}" uncordon "$node_name" || warn "uncordon failed for ${node_name} (re-run manually)"
  ok "Node ${node_name} $([[ $UPGRADE -eq 1 ]] && echo upgraded || echo replaced) and back in rotation"
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
  # "Ready,SchedulingDisabled" is Ready. Matching the column exactly counted a
  # merely cordoned node as unhealthy — and a cordoned node is the state THIS
  # script leaves behind when it stops mid-node, so the check blocked its own
  # retry until someone uncordoned by hand.
  not_ready="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/{c++} END{print c+0}')"
  [[ "$not_ready" == "0" ]] || die "${not_ready} node(s) not Ready — stabilize the cluster first"
  cordoned="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null | awk '$2 ~ /SchedulingDisabled/{printf "%s ", $1}')"
  [[ -z "$cordoned" ]] || warn "already cordoned (interrupted run?): ${cordoned}— uncordon by hand any node this run does not touch."
  ok "Cluster healthy — proceeding"
else
  ok "dry-run — skipping live pre-flight"
fi

if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  hr
  # The prompt described the REPLACE path in both modes. `--upgrade` destroys
  # nothing and wipes nothing — it reboots each node into a new Talos version and
  # keeps its disk, identity and etcd membership — so the warning was frightening
  # and wrong for half the runs that reach it.
  if [[ $UPGRADE -eq 1 ]]; then
    warn "This will upgrade Talos IN PLACE, one node at a time, on ${PROVIDER}."
    warn "No instance is destroyed and no disk is wiped; each node reboots once."
    read -rp "Proceed with the rolling upgrade? [y/N] " a
  else
    warn "This will DESTROY and recreate node instances one at a time on ${PROVIDER}."
    warn "System disks are wiped (OS only); Longhorn data disks are preserved."
    read -rp "Proceed with rolling replacement? [y/N] " a
  fi
  [[ "$a" == [yY] ]] || die "aborted by operator"
fi

# Tell CNPG a maintenance is on for the whole roll, and take it back off however
# this ends — including on failure, where leaving the budgets relaxed would be
# worse than the drain that failed.
if [[ $DRY_RUN -eq 0 ]]; then
  cnpg_maintenance true
  trap 'cnpg_maintenance false' EXIT
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
