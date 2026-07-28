#!/usr/bin/env bash
# ==============================================================================
# OpenAether — teardown COMPLET et idempotent d'une flotte (edges + management)
#
# POURQUOI
#   The destruction order is not free: every CAPI child cluster must disappear
#   BEFORE the management, otherwise nothing drives its VMs any more and they
#   stay billed. `task destroy` alone only handles the management.
#   This script chains, in the right order and unattended:
#     1. `edge-down` on every child cluster still present (CAPI cascade);
#     2. `tofu destroy` du management ;
#     3. a report of what is left to purge by hand (buckets, images, keypairs…),
#        deliberately NOT destroyed here: these objects outlive the clusters and
#        deleting them is a choice, not a consequence.
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
    --keep-images) shift ;;   # accepté pour la symétrie, sans effet ici
    *) echo "✗ flag inconnu: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"

info() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 1. les edges
#
# ⚠️ FAIL-SAFE (lesson from 2026-07-26): if the management is unreachable, we
# CANNOT know whether it was driving child clusters. Destroying the management
# in that case leaves their VMs orphaned and BILLED — exactly what happened
# when an earlier version of this script settled for a warning. We STOP, unless
# --force-no-edges is passed (the operator then asserts there is no child, or
# has already purged them on the provider side).
info "Étape 1/3 — clusters enfants CAPI"
if [ ! -r "$KUBECONFIG" ] || ! kubectl cluster-info >/dev/null 2>&1; then
  if [ "$FORCE_NO_EDGES" -eq 1 ]; then
    warn "management injoignable — étape sautée (--force-no-edges assumé)."
  else
    cat >&2 <<'EOT'

✗ ARRÊT : le cluster de management est injoignable (kubeconfig absent ou API down).
  Impossible de vérifier qu'aucun cluster enfant CAPI ne subsiste. Détruire le
  management maintenant rendrait leurs VMs ORPHELINES et FACTURÉES.

  Que faire :
    • kubeconfig perdu ? le régénérer :
        cd infrastructure/opentofu/cluster && tofu output -raw kubeconfig > kubeconfig
        (ou  talosctl -e <tunnel> -n <cp-ip> kubeconfig ./kubeconfig --force)
    • enfants déjà supprimés / jamais créés ? relancer avec --force-no-edges
    • dans le doute : inventorier côté provider AVANT (chercher le préfixe des
      clusters enfants dans les VMs, LB, réseaux) — cf. docs/backlog.md
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
    ok "aucun cluster enfant"
  else
    printf '  %s clusters enfants: %s\n' "${#EDGES[@]}" "$(printf '%s ' "${EDGES[@]%% *}")"
    for e in "${EDGES[@]}"; do
      name="${e%% *}"; ns="${e##* }"
      if ! "$ROOT/scripts/ops/edge-down.sh" "$name" --namespace "$ns" --timeout 900 \
             $([ "$ASSUME_YES" -eq 1 ] && echo --yes); then
        warn "edge-down $name a ÉCHOUÉ."
        if [ "$FORCE_NO_EDGES" -eq 1 ]; then
          warn "--force-no-edges : on continue malgré tout (VMs à vérifier côté provider)."
        else
          cat >&2 <<EOT

✗ ARRÊT avant de toucher au management : '$name' n'a pas été détruit proprement.
  Détruire le management maintenant laisserait ses VMs orphelines. Purger d'abord
  côté provider, puis relancer (ce script est idempotent).
EOT
          exit 1
        fi
      fi
    done
  fi
fi

# ----------------------------------------------------------- 2. le management
info "Étape 2/3 — cluster de management ($ROLE / $PROVIDER)"
if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Détruire le management $ROLE-$PROVIDER ? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "abandon"; exit 1; }
fi
( cd "$ROOT" && TF_CLI_ARGS_destroy=-auto-approve task destroy ROLE="$ROLE" PROVIDER="$PROVIDER" ) \
  && ok "management détruit" \
  || warn "le destroy du management a échoué — relancer après correction (idempotent)"

# ------------------------------------------------- 3. ce qui reste (rapport)
info "Étape 3/3 — reste à purger MANUELLEMENT (survit volontairement au teardown)"
CN="$(grep -E '^[[:space:]]*cluster_name' "$CLUSTER_DIR/envs/$ROLE-$PROVIDER.tfvars" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')"
ENVN="$(grep -E '^[[:space:]]*environment' "$CLUSTER_DIR/envs/$ROLE-$PROVIDER.tfvars" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')"
cat <<EOT
  Buckets S3 (state, artefacts, backups) — les détruire supprime aussi la
  possibilité de restaurer :
    s3-${CN:-<projet>}-${PROVIDER}-tfstate-${ENVN:-<env>}      (+ -backup)
    s3-${CN:-<projet>}-${PROVIDER}-${ROLE}-${ENVN:-<env>}      (+ -backup)
    s3-${CN:-<projet>}-*-backups-${ENVN:-<env>}                (restic, tous providers)
  Images Talos (réutilisables — les garder évite un rebuild, ~1 h sur Outscale) :
    task talos-image PROVIDER=$PROVIDER  ré-applique ; le root talos-image a son
    propre state (bucket s3-${CN:-<projet>}-${PROVIDER}-talos-image).
  Objets créés hors OpenTofu pour CAPI (à recréer au prochain déploiement) :
    keypair Outscale 'openaether-capi', FIP OpenStack pré-créée (certSANs edge-2).
  Local : kubeconfig, talosconfig, edge-*.kubeconfig, restic-escrow-*.txt
EOT
ok "fleet-down terminé"
