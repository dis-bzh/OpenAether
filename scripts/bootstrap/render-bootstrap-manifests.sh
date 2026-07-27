#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenAether — Render Bootstrap Manifests
# Generates static Cilium + Flux manifests for Talos
# inlineManifests injection.
#
# Prerequisites: helm, curl
# Usage:
#   ./scripts/bootstrap/render-bootstrap-manifests.sh           # production
#   ./scripts/bootstrap/render-bootstrap-manifests.sh --local   # local Docker testing
#   ./scripts/bootstrap/render-bootstrap-manifests.sh --check   # n'écrit RIEN : vérifie que
#                                                     # les artefacts committés
#                                                     # correspondent au générateur
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Surchargeable pour --check (rendu dans un dossier jetable, puis diff).
# ⚠️ DEUX niveaux : ce script vit dans scripts/bootstrap/. Avec un seul `..`
# il écrivait dans scripts/infrastructure/… — un répertoire FANTÔME créé par
# le `mkdir -p` ci-dessous, jamais lu par OpenTofu. `task render-manifests`
# semblait donc fonctionner tout en ne régénérant JAMAIS les artefacts
# committés : c'est l'origine de leur dérive vis-à-vis du générateur
# (constaté le 2026-07-27).
MANIFESTS_DIR="${OPENAETHER_MANIFESTS_DIR:-${SCRIPT_DIR}/../../infrastructure/opentofu/cluster/bootstrap-manifests}"

# Mode: production (default) or local Docker testing
LOCAL_MODE=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_MODE=true
  shift
fi

# ─────────────────────────────────────────────────────────────
# --check : garde-fou anti-dérive
#
# Un artefact généré peut diverger de son générateur en SILENCE — c'est arrivé :
# les cilium*.yaml committés portaient trois `--set` absents de ce script, si
# bien qu'un simple `task render-manifests` cassait Istio ambient sans que rien
# ne le signale. Ce mode rejoue le rendu dans un dossier jetable et compare.
#
# Ne contrôle QUE les manifests que NOUS générons (cilium.yaml, cilium-local.yaml).
# flux-install.yaml est un téléchargement amont : son évolution est un autre
# signal (nouvelle release Flux), pas une dérive de notre configuration.
# ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
  command -v diff >/dev/null 2>&1 || { echo "✗ diff requis" >&2; exit 1; }
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "🔍 Vérification des artefacts committés contre le générateur…"
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" >/dev/null
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" --local >/dev/null
  # Le rendu brut de helm porte des espaces en fin de ligne ; l'artefact committé,
  # lui, est passé par les hooks pre-commit (`trim trailing whitespace`,
  # `fix end of files`). Comparer les deux tels quels rendrait le contrôle rouge
  # en permanence — on normalise donc des DEUX côtés, exactement comme le hook.
  norm() { sed -e 's/[[:space:]]*$//' "$1"; }
  drift=0
  for f in cilium.yaml cilium-local.yaml; do
    if ! diff -q <(norm "${MANIFESTS_DIR}/${f}") <(norm "${tmp}/${f}") >/dev/null 2>&1; then
      echo "  ❌ ${f} diffère du rendu (extrait) :"
      diff <(norm "${MANIFESTS_DIR}/${f}") <(norm "${tmp}/${f}") | head -20 | sed 's/^/      /'
      drift=1
    else
      echo "  ✓ ${f}"
    fi
  done
  if [[ "$drift" -eq 1 ]]; then
    cat >&2 <<'EOT'

✗ Les artefacts committés ne correspondent plus au générateur.
  Avant de régénérer, décider QUI a raison :
    • l'artefact (un `--set` a été ajouté à la main et doit passer dans le script) ;
    • le script (l'artefact est simplement périmé → régénérer et committer).
  Régénérer efface l'écart sans le montrer — c'est ainsi qu'Istio ambient a été
  cassé le 2026-07-26.
EOT
    exit 1
  fi
  echo "OK — artefacts de bootstrap à jour vis-à-vis du générateur."
  exit 0
fi

# Versions — update these when upgrading
CILIUM_VERSION="${CILIUM_VERSION:-1.19.2}"
FLUX_VERSION="${FLUX_VERSION:-}"

mkdir -p "${MANIFESTS_DIR}"

# ─────────────────────────────────────────────────────
# 1. Render Cilium manifest via helm template
# ─────────────────────────────────────────────────────
if [[ "$LOCAL_MODE" == "true" ]]; then
  CILIUM_OUTPUT="${MANIFESTS_DIR}/cilium-local.yaml"
  echo "🔧 Rendering Cilium ${CILIUM_VERSION} manifest (LOCAL mode — simplified for Docker)..."
else
  CILIUM_OUTPUT="${MANIFESTS_DIR}/cilium.yaml"
  echo "🔧 Rendering Cilium ${CILIUM_VERSION} manifest (PRODUCTION mode)..."
fi

helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1
helm repo update cilium >/dev/null 2>&1

if [[ "$LOCAL_MODE" == "true" ]]; then
  # Local mode: simplified Cilium for Docker/WSL2
  # - kubeProxyReplacement=false: use iptables (no eBPF kube-proxy replacement)
  # - encryption=false: no WireGuard (simpler for single-node Docker)
  #
  # ⚠️ socketLB.enabled=true est OBLIGATOIRE ici, bien que kubeProxyReplacement
  # soit à false. Sans lui le chart émet `bpf-lb-sock: "false"`, ce qui rend
  # `bpf-lb-sock-hostns-only` INOPÉRANT : les pods hostNetwork (kube-apiserver)
  # n'atteignent alors plus les ClusterIP et les dry-run Flux expirent sur les
  # webhooks. Le correctif vivait dans l'artefact committé, pas dans ce script —
  # régénérer réintroduisait donc le bug (piégé par --check le 2026-07-27).
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
    --set socketLB.enabled=true \
    --set cni.exclusive=false \
    --set socketLB.hostNamespaceOnly=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set operator.replicas=1 \
    --set encryption.enabled=false \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    > "${CILIUM_OUTPUT}"
  echo "  ✅ Written to bootstrap-manifests/cilium-local.yaml"
else
  # Production mode: full Cilium with WireGuard encryption + kube-proxy replacement
  #
  # ⚠️ Ces deux réglages sont EXIGÉS par Istio ambient (apps/base/istio) — ne pas
  # les retirer sans retirer le mesh, sinon istio-cni ne devient jamais Ready :
  #  - cni.exclusive=false : Cilium réécrit sinon 05-cilium.conflist en boucle et
  #    en retire le plugin chaîné istio-cni (« conflicting component constantly
  #    reverting our work ») → /readyz 503 → Helm install timeout → ztunnel,
  #    services-gateway et istio-authorizationpolicies bloqués en cascade ;
  #  - socketLB.hostNamespaceOnly=true : sans ça le socket-LB court-circuite la
  #    redirection ambient pour les process host-network.
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set socketLB.enabled=true \
    --set cni.exclusive=false \
    --set socketLB.hostNamespaceOnly=true \
    --set nodeSelectorLabels=true \
    --set bpf.hostLegacyRouting=false \
    --set bpf.masquerade=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.enabled=false \
    --set operator.replicas=1 \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    > "${CILIUM_OUTPUT}"
  echo "  ✅ Written to bootstrap-manifests/cilium.yaml"
fi

# helm laisse des espaces en fin de ligne ; le hook pre-commit `trim trailing
# whitespace` les retire au commit. Sans cette normalisation ICI, chaque rendu
# salit l'arbre de travail et l'artefact committé ne peut jamais être identique
# au rendu — ce qui obligeait le contrôle --check à comparer « modulo espaces ».
sed -i 's/[[:space:]]*$//' "${CILIUM_OUTPUT}"

# ─────────────────────────────────────────────────────
# 2. Download Flux install manifest
# ─────────────────────────────────────────────────────
# ⚠️ TÉLÉCHARGEMENT VOLONTAIREMENT OPT-IN (OPENAETHER_REFRESH_FLUX=1).
#
# Deux raisons, toutes deux constatées le 2026-07-27 :
#  1. sans FLUX_VERSION, l'URL est `releases/latest` — un simple
#     `task render-manifests` BUMPAIT Flux vers la dernière version publiée,
#     sans que rien ne le demande ni ne le signale ;
#  2. l'artefact committé n'est PAS un install.yaml amont : il embarque un
#     contrôleur de plus, `source-watcher` (7 Deployments / 15 CRD au lieu de
#     6 / 14). Le réécrire avec l'install.yaml standard SUPPRIMERAIT ce
#     contrôleur du bootstrap.
# Pour le régénérer sciemment : figer FLUX_VERSION *et* reconstituer le jeu de
# composants (`flux install --export --components-extra=source-watcher`).
if [[ "$LOCAL_MODE" == "false" && "${OPENAETHER_SKIP_FLUX:-0}" != "1" \
      && "${OPENAETHER_REFRESH_FLUX:-0}" == "1" ]]; then
  echo "🔧 Downloading Flux install manifest${FLUX_VERSION:+ (${FLUX_VERSION})}..."
  if [[ -z "${FLUX_VERSION}" ]]; then
    echo "  ⚠️  FLUX_VERSION vide → 'latest' : le rendu ne sera pas reproductible." >&2
  fi
  FLUX_URL="https://github.com/fluxcd/flux2/releases/latest/download/install.yaml"
  if [[ -n "${FLUX_VERSION}" ]]; then
    FLUX_URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml"
  fi
  curl -sL "${FLUX_URL}" > "${MANIFESTS_DIR}/flux-install.yaml"
  if [ ! -s "${MANIFESTS_DIR}/flux-install.yaml" ] || [ "$(wc -c < "${MANIFESTS_DIR}/flux-install.yaml")" -lt 1000 ]; then
    echo "  ❌ Flux manifest download failed or is too small"
    exit 1
  fi
  echo "  ✅ Written to bootstrap-manifests/flux-install.yaml"
fi

# ─────────────────────────────────────────────────────
# 3. Summary
# ─────────────────────────────────────────────────────
echo ""
echo "📋 Bootstrap manifests rendered:"
echo "   Cilium: ${CILIUM_VERSION} ($([ "$LOCAL_MODE" == "true" ] && echo "local — simplified" || echo "production — WireGuard"))"
[[ "$LOCAL_MODE" == "false" ]] && echo "   Flux:   ${FLUX_VERSION:-latest}"
echo ""
echo "   Files:"
ls -lh "${MANIFESTS_DIR}"/*.yaml 2>/dev/null || true
ls -lh "${MANIFESTS_DIR}"/*.tftpl 2>/dev/null || true
echo ""
if [[ "$LOCAL_MODE" == "true" ]]; then
  echo "💡 Local manifests generated. Drive the 3-CP Docker cluster with:"
  echo "   ./scripts/test-talos-local.sh        # or: task local-test"
  echo "   (it reads bootstrap-manifests/cilium-local.yaml into TF_VAR_cilium_manifest)"
else
  echo "💡 Commit these files to the repository."
  echo "   Re-run this script when upgrading Cilium or Flux versions."
fi
