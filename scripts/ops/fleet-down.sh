#!/usr/bin/env bash
# ==============================================================================
# OpenAether — COMPLETE, idempotent fleet teardown (edges + management)
#
# The destruction order is not free: every CAPI child must disappear BEFORE the
# management, or nothing drives its VMs any more and they stay billed. `task
# destroy` alone only handles the management. This script chains, unattended:
#   1. `edge-down` on every child cluster still present (CAPI cascade);
#   2. `tofu destroy` of the management;
#   3. a report of what is left to purge by hand (buckets, images, keypairs…),
#      deliberately NOT destroyed here: those outlive the clusters, so deleting
#      them is a choice, not a consequence.
#
# Idempotent: re-runnable at any time; skips whatever is already gone.
#
# Usage:
#   fleet-down.sh <provider> [--role management] [--yes] [--keep-images]
#   The management KUBECONFIG is derived from infrastructure/opentofu/cluster/.
# ==============================================================================
set -uo pipefail

PROVIDER="${1:?usage: fleet-down.sh <scaleway|ovh|outscale|proxmox> [--role management] [--yes]}"
shift
ROLE=management
ASSUME_YES=0
FORCE_NO_EDGES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --force-no-edges) FORCE_NO_EDGES=1; shift ;;
    --keep-images) shift ;;   # accepted for symmetry, no effect here
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"

# Any step that fails flips this; the script exits non-zero at the end. It used
# to report success after a management destroy that never started, leaving
# 7 VMs running and billed (2026-07-28).
FAILED=0

info() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# ------------------------------------------------------------------ 1. edges
#
# ⚠️ FAIL-SAFE (lesson from 2026-07-26): if the management is unreachable, we
# CANNOT know whether it was driving child clusters. Destroying the management
# in that case leaves their VMs orphaned and BILLED — exactly what happened
# when an earlier version of this script settled for a warning. We STOP, unless
# --force-no-edges is passed (the operator then asserts there is no child, or
# has already purged them on the provider side).
info "Step 1/3 — CAPI child clusters"
if [ ! -r "$KUBECONFIG" ] || ! kubectl cluster-info >/dev/null 2>&1; then
  if [ "$FORCE_NO_EDGES" -eq 1 ]; then
    warn "management unreachable — step skipped (--force-no-edges assumed)."
  else
    cat >&2 <<'EOT'

✗ STOP: the management cluster is unreachable (no kubeconfig, or API down).
  Cannot verify that no CAPI child cluster remains. Destroying the management
  now would leave their VMs ORPHANED and BILLED.

  What to do:
    • kubeconfig lost? regenerate it:
        cd infrastructure/opentofu/cluster && tofu output -raw kubeconfig > kubeconfig
        (or  talosctl -e <tunnel> -n <cp-ip> kubeconfig ./kubeconfig --force)
    • children already deleted, or a bootstrap that never reached Kubernetes
      (so no CAPI controller ever ran)? re-run asserting there is none:
        task fleet-down PROVIDER=<provider> -- --force-no-edges --yes
      The bare -- is not optional: without it Task keeps the flags itself.
    • when in doubt: inventory on the provider side FIRST (look for the child
      clusters' prefix among VMs, LBs, networks) — see docs/backlog.md
EOT
    exit 1
  fi
else
  # ⚠️ Bare `cluster` is AMBIGUOUS: CNPG also exposes a `Cluster` kind
  # (postgresql.cnpg.io). When the CAPI CRDs are not installed — management
  # partially destroyed, providers not yet reconciled — `kubectl get cluster`
  # returns the DATABASES (observed 2026-07-27: grafana-db, zitadel-db) and this
  # script would run `edge-down` against them. Always qualify the API group.
  mapfile -t EDGES < <(kubectl get clusters.cluster.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace}{"\n"}{end}' 2>/dev/null)
  if [ "${#EDGES[@]}" -eq 0 ]; then
    ok "no child cluster"
  else
    printf '  %s child clusters: %s\n' "${#EDGES[@]}" "$(printf '%s ' "${EDGES[@]%% *}")"
    for e in "${EDGES[@]}"; do
      name="${e%% *}"; ns="${e##* }"
      if ! "$ROOT/scripts/ops/edge-down.sh" "$name" --namespace "$ns" --timeout 900 \
             $([ "$ASSUME_YES" -eq 1 ] && echo --yes); then
        warn "edge-down $name FAILED."
        if [ "$FORCE_NO_EDGES" -eq 1 ]; then
          warn "--force-no-edges: continuing anyway (check the VMs on the provider side)."
          FAILED=1
        else
          cat >&2 <<EOT

✗ STOPPING before touching the management: '$name' was not cleanly destroyed.
  Destroying the management now would orphan its VMs. Purge them on the provider
  side first, then re-run (this script is idempotent).
EOT
          exit 1
        fi
      fi
    done
  fi
fi

# -------------------------------------------------------- 2. the management
info "Step 2/3 — management cluster ($ROLE / $PROVIDER)"
if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Destroy the $ROLE-$PROVIDER management? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "aborted"; exit 1; }
fi
( cd "$ROOT" && TF_CLI_ARGS_destroy=-auto-approve task destroy ROLE="$ROLE" PROVIDER="$PROVIDER" ) \
  && ok "management destroyed" \
  || { warn "the management destroy FAILED — re-run after fixing (idempotent)"; FAILED=1; }

# ------------------------------------------------ 3. what is left (report)
info "Step 3/3 — left to purge MANUALLY (deliberately survives the teardown)"
CN="$(grep -E '^[[:space:]]*cluster_name' "$CLUSTER_DIR/envs/$ROLE-$PROVIDER.tfvars" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')"
ENVN="$(grep -E '^[[:space:]]*environment' "$CLUSTER_DIR/envs/$ROLE-$PROVIDER.tfvars" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')"
cat <<EOT
  S3 buckets (state, artifacts, backups) — destroying them also removes any
  possibility of restoring:
    (each of the first two also has a "-backup" twin)
    s3-${CN:-<project>}-${PROVIDER}-tfstate-${ENVN:-<env>}
    s3-${CN:-<project>}-${PROVIDER}-${ROLE}-${ENVN:-<env>}
    s3-${CN:-<project>}-*-backups-${ENVN:-<env>}   (restic, all providers)
  Talos images (reusable — keeping them avoids a rebuild, ~1 h on Outscale):
    task talos-image PROVIDER=$PROVIDER  re-applies; the talos-image root has
    its own state (bucket s3-${CN:-<project>}-${PROVIDER}-talos-image).
  Objects created outside OpenTofu for CAPI (to recreate on the next deployment):
    Outscale keypair 'openaether-capi', pre-created OpenStack FIP (edge-2 certSANs).
  Local: kubeconfig, talosconfig, edge-*.kubeconfig, restic-escrow-*.txt
EOT
if [ "$FAILED" -ne 0 ]; then
  printf '\n✗ fleet-down INCOMPLETE — see the ⚠ above. Resources may still exist\n'  >&2
  printf '  and be BILLED. Check the provider, then re-run (idempotent).\n' >&2
  exit 1
fi
ok "fleet-down complete"
