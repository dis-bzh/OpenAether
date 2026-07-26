#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenAether — Render Bootstrap Manifests
# Generates static Cilium + Flux manifests for Talos
# inlineManifests injection.
#
# Prerequisites: helm, curl
# Usage:
#   ./scripts/render-bootstrap-manifests.sh           # production
#   ./scripts/render-bootstrap-manifests.sh --local   # local Docker testing
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../infrastructure/opentofu/cluster/bootstrap-manifests"

# Mode: production (default) or local Docker testing
LOCAL_MODE=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_MODE=true
  shift
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
  helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
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

# ─────────────────────────────────────────────────────
# 2. Download Flux install manifest
# ─────────────────────────────────────────────────────
if [[ "$LOCAL_MODE" == "false" ]]; then
  echo "🔧 Downloading Flux install manifest${FLUX_VERSION:+ (${FLUX_VERSION})}..."
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
