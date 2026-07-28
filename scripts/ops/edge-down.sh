#!/usr/bin/env bash
# ==============================================================================
# OpenAether — CLEAN decommission of a CAPI child cluster (idempotent)
#
# POURQUOI CE SCRIPT
#   Removing the file from the kustomization and letting Flux `prune` IS NOT
#   ENOUGH: Flux deletes every object at once, in no order. CAPI needs the
#   `Cluster` to go FIRST so the cascade works (ownerReferences); if its
#   <Infra>Cluster is pruned before the machines, the provider loses the cloud
#   client it needs to destroy them and loops on "<Infra>Cluster is not
#   available yet" — machines stuck on finalizers, orphaned VMs BILLED
#   (observed for real on Scaleway, twice).
#
#   Here we do the opposite, in the right order:
#     1. SUSPEND the Flux Kustomizations that manage the `Cluster` — without
#        this Flux recreates it as soon as it is deleted and the cascade never
#        starts (hit on 2026-07-27: loops to timeout, machines untouched);
#     2. `kubectl delete cluster <nom>` → CAPI cascade proprement (control plane,
#        MachineDeployment, Machines, infra objects) while everything is still there;
#     3. wait for everything to disappear;
#     4. safety net: if the provider stayed stuck past the timeout, lift the
#        finalizers of the remaining infra objects and REPORT the potentially
#        orphaned VMs to check in the provider console.
#   Only then: remove the file from apps/clusters/kustomization.yaml
#   (the Flux prune will have nothing left to delete → no-op).
#
# Idempotent: re-runnable, does nothing if the cluster does not exist.
#
# Usage:
#   edge-down.sh <cluster> [--namespace capi-clusters] [--timeout 900] [--yes]
#   KUBECONFIG must point at the MANAGEMENT cluster.
# ==============================================================================
set -uo pipefail

CLUSTER="${1:?usage: edge-down.sh <cluster> [--namespace ns] [--timeout s] [--yes]}"
shift
NS=capi-clusters
TIMEOUT=900
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --yes | -y)  ASSUME_YES=1; shift ;;
    *) echo "✗ flag inconnu: $1" >&2; exit 2 ;;
  esac
done

info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# ⚠️ Always qualify `clusters.cluster.x-k8s.io`: the `Cluster` kind is also
# CNPG's (postgresql.cnpg.io). Without the CAPI CRDs installed, an unqualified
# `kubectl delete cluster <name>` would target a DATABASE.
command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl requis" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "✗ KUBECONFIG ne pointe aucun cluster joignable" >&2; exit 1; }

if ! kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" >/dev/null 2>&1; then
  ok "cluster '$CLUSTER' already absent (nothing to do)"
  exit 0
fi

# Inventory before deletion — used for the final report.
mapfile -t MACHINES < <(kubectl get machines -n "$NS" \
  -l "cluster.x-k8s.io/cluster-name=$CLUSTER" -o name 2>/dev/null)
info "Cluster '$CLUSTER' (ns $NS): ${#MACHINES[@]} machine(s) to destroy"

if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Permanently destroy '$CLUSTER' and its VMs? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "abandon"; exit 1; }
fi

# 1. SUSPEND Flux first — otherwise the deletion is undone in a loop.
#
# ⚠️ Trap hit on 2026-07-27: the `<cluster>-cluster` Kustomization reapplies
# the `Cluster` object every 10 min. Once deleted, it was RECREATED before the
# CAPI cascade had started — the Machines never got a deletionTimestamp and
# this script looped to the timeout without reporting anything.
# So we suspend both the Kustomization that manages it AND the parent one
# (`capi-clusters`), which would recreate the former.
for k in "${CLUSTER}-cluster" capi-clusters; do
  if kubectl get kustomization -n flux-system "$k" >/dev/null 2>&1; then
    kubectl patch kustomization -n flux-system "$k" --type=merge \
      -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 && info "Flux suspendu : $k"
  fi
done

# 2. Delete the Cluster → CAPI cascades (non-blocking: we follow it ourselves).
#    The error is NOT swallowed: a rejected delete (unreachable webhook, RBAC…)
#    must show immediately, not after 15 min of silent waiting.
info "kubectl delete cluster $CLUSTER (cascade CAPI)…"
if ! kubectl delete clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --wait=false; then
  echo "✗ the Cluster deletion was REFUSED (see the error above)." >&2
  exit 1
fi

# 3. Wait for everything to disappear.
info "Attente de la fin de la cascade (timeout ${TIMEOUT}s)…"
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  left=$(kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --no-headers 2>/dev/null | wc -l)
  mach=$(kubectl get machines -n "$NS" -l "cluster.x-k8s.io/cluster-name=$CLUSTER" \
           --no-headers 2>/dev/null | wc -l)
  if [ "$left" = 0 ] && [ "$mach" = 0 ]; then
    ok "cluster '$CLUSTER' fully deleted"
    exit 0
  fi
  printf '  … cluster=%s machines=%s\n' "$left" "$mach"
  sleep 15
done

# 4. Safety net — the provider is stuck (known bug: see docs/backlog.md).
warn "timeout after ${TIMEOUT}s — the provider did not finish the cascade."
warn "Lifting finalizers on the remaining infra objects (the VMs may survive!):"
for kind in scalewaymachine oscmachine openstackmachine scalewaycluster osccluster openstackcluster; do
  for obj in $(kubectl get "$kind" -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
    kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && warn "  finalizers lifted: $obj"
  done
done
for obj in $(kubectl get machines -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
  kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
done
kubectl patch clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1

cat >&2 <<EOT

⚠ MANUAL ACTION REQUIRED — check that no VM survives on the provider side:
    Scaleway : scw instance server list   (ou console)  → chercher '${CLUSTER}-'
    OVH      : openstack server list                    → chercher '${CLUSTER}-'
    Outscale : ReadVms (API)                            → chercher les tags ${CLUSTER}
  The Kubernetes objects were forced, but the matching cloud resources are
  NOT guaranteed to be destroyed.
EOT
exit 1
