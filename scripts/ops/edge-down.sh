#!/usr/bin/env bash
# ==============================================================================
# OpenAether — décommission PROPRE d'un cluster enfant CAPI (idempotent)
#
# POURQUOI CE SCRIPT
#   Retirer le fichier du kustomization et laisser Flux `prune` NE SUFFIT PAS :
#   Flux supprime tous les objets d'un coup, sans ordre. Or CAPI a besoin que le
#   `Cluster` parte EN PREMIER pour cascader (ownerReferences) ; si son
#   <Infra>Cluster est pruné avant les machines, le provider perd le client cloud
#   dont il a besoin pour les détruire et boucle sur « <Infra>Cluster is not
#   available yet » — machines bloquées sur finalizers, VMs orphelines FACTURÉES
#   (constaté en réel sur Scaleway, 2 fois).
#
#   Ici on fait l'inverse, dans le bon ordre :
#     1. on SUSPEND les Kustomizations Flux qui gèrent le `Cluster` — sans ça
#        Flux le recrée aussitôt supprimé et la cascade ne démarre jamais
#        (vécu le 2026-07-27 : boucle jusqu'au timeout, machines intactes) ;
#     2. `kubectl delete cluster <nom>` → CAPI cascade proprement (control plane,
#        MachineDeployment, Machines, objets infra) pendant que tout est encore là ;
#     3. on attend la disparition complète ;
#     4. filet de sécurité : si le provider est resté bloqué au-delà du timeout,
#        on lève les finalizers des objets infra restants et on SIGNALE les VMs
#        potentiellement orphelines à vérifier côté console.
#   Ensuite seulement : retirer le fichier de apps/clusters/kustomization.yaml
#   (le prune Flux n'aura plus rien à supprimer → no-op).
#
# Idempotent : relançable, ne fait rien si le cluster n'existe pas.
#
# Usage:
#   edge-down.sh <cluster> [--namespace capi-clusters] [--timeout 900] [--yes]
#   KUBECONFIG doit pointer le cluster de MANAGEMENT.
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

# ⚠️ Toujours qualifier `clusters.cluster.x-k8s.io` : le kind `Cluster` est aussi
# celui de CNPG (postgresql.cnpg.io). Sans CRDs CAPI installées, un `kubectl
# delete cluster <nom>` non qualifié viserait une BASE DE DONNÉES.
command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl requis" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "✗ KUBECONFIG ne pointe aucun cluster joignable" >&2; exit 1; }

if ! kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" >/dev/null 2>&1; then
  ok "cluster '$CLUSTER' déjà absent (rien à faire)"
  exit 0
fi

# Inventaire avant suppression — sert au rapport final.
mapfile -t MACHINES < <(kubectl get machines -n "$NS" \
  -l "cluster.x-k8s.io/cluster-name=$CLUSTER" -o name 2>/dev/null)
info "Cluster '$CLUSTER' (ns $NS) : ${#MACHINES[@]} machine(s) à détruire"

if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Détruire définitivement '$CLUSTER' et ses VMs ? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "abandon"; exit 1; }
fi

# 1. SUSPENDRE Flux d'abord — sinon la suppression est annulée en boucle.
#
# ⚠️ Piège vécu le 2026-07-27 : la Kustomization `<cluster>-cluster` réapplique
# l'objet `Cluster` toutes les 10 min. Supprimé, il était RECRÉÉ avant que la
# cascade CAPI n'ait commencé — les Machines n'obtenaient jamais de
# deletionTimestamp et ce script bouclait jusqu'au timeout sans rien signaler.
# On suspend donc la Kustomization qui le gère ET la Kustomization parente
# (`capi-clusters`), qui recréerait la première.
for k in "${CLUSTER}-cluster" capi-clusters; do
  if kubectl get kustomization -n flux-system "$k" >/dev/null 2>&1; then
    kubectl patch kustomization -n flux-system "$k" --type=merge \
      -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 && info "Flux suspendu : $k"
  fi
done

# 2. Suppression du Cluster → CAPI cascade (non bloquant : on suit nous-mêmes).
#    L'erreur n'est PAS avalée : un delete rejeté (webhook injoignable, RBAC…)
#    doit se voir tout de suite, pas au bout de 15 min d'attente muette.
info "kubectl delete cluster $CLUSTER (cascade CAPI)…"
if ! kubectl delete clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --wait=false; then
  echo "✗ la suppression du Cluster a été REFUSÉE (voir l'erreur ci-dessus)." >&2
  exit 1
fi

# 3. Attente de la disparition complète.
info "Attente de la fin de la cascade (timeout ${TIMEOUT}s)…"
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  left=$(kubectl get clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --no-headers 2>/dev/null | wc -l)
  mach=$(kubectl get machines -n "$NS" -l "cluster.x-k8s.io/cluster-name=$CLUSTER" \
           --no-headers 2>/dev/null | wc -l)
  if [ "$left" = 0 ] && [ "$mach" = 0 ]; then
    ok "cluster '$CLUSTER' entièrement supprimé"
    exit 0
  fi
  printf '  … cluster=%s machines=%s\n' "$left" "$mach"
  sleep 15
done

# 4. Filet de sécurité — le provider est bloqué (bug connu : cf. docs/backlog.md).
warn "timeout après ${TIMEOUT}s — le provider n'a pas fini la cascade."
warn "Levée des finalizers sur les objets infra restants (les VMs peuvent survivre !) :"
for kind in scalewaymachine oscmachine openstackmachine scalewaycluster osccluster openstackcluster; do
  for obj in $(kubectl get "$kind" -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
    kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && warn "  finalizers levés : $obj"
  done
done
for obj in $(kubectl get machines -n "$NS" -o name 2>/dev/null | grep -- "$CLUSTER" || true); do
  kubectl patch "$obj" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
done
kubectl patch clusters.cluster.x-k8s.io "$CLUSTER" -n "$NS" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1

cat >&2 <<EOT

⚠ ACTION MANUELLE REQUISE — vérifier qu'aucune VM ne survit côté provider :
    Scaleway : scw instance server list   (ou console)  → chercher '${CLUSTER}-'
    OVH      : openstack server list                    → chercher '${CLUSTER}-'
    Outscale : ReadVms (API)                            → chercher les tags ${CLUSTER}
  Les objets Kubernetes ont été forcés, mais les ressources cloud correspondantes
  ne sont PAS garanties détruites.
EOT
exit 1
