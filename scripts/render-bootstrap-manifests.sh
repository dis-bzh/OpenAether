#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenAether — Render Bootstrap Manifests
# Generates static Cilium and ArgoCD manifests for Talos
# inlineManifests injection.
#
# Prerequisites: helm, curl
# Usage: ./scripts/render-bootstrap-manifests.sh
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../infrastructure/opentofu/bootstrap-manifests"

# Versions — update these when upgrading
CILIUM_VERSION="${CILIUM_VERSION:-1.19.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.3.2}"

mkdir -p "${MANIFESTS_DIR}"

# ─────────────────────────────────────────────────────
# 1. Render Cilium manifest via helm template
# ─────────────────────────────────────────────────────
echo "🔧 Rendering Cilium ${CILIUM_VERSION} manifest..."

helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1
helm repo update cilium >/dev/null 2>&1

helm template cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set hubble.enabled=false \
  --set operator.replicas=1 \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  > "${MANIFESTS_DIR}/cilium.yaml"

echo "  ✅ Written to bootstrap-manifests/cilium.yaml"

# ─────────────────────────────────────────────────────
# 2. Download ArgoCD install manifest
# ─────────────────────────────────────────────────────
echo "🔧 Downloading ArgoCD ${ARGOCD_VERSION} install manifest..."

curl -sL \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
  > "${MANIFESTS_DIR}/argocd-install.yaml"

# Verify download succeeded (file should be >1KB)
if [ ! -s "${MANIFESTS_DIR}/argocd-install.yaml" ] || [ "$(wc -c < "${MANIFESTS_DIR}/argocd-install.yaml")" -lt 1000 ]; then
  echo "  ❌ ArgoCD manifest download failed or is too small"
  exit 1
fi

echo "  ✅ Written to bootstrap-manifests/argocd-install.yaml"

# ─────────────────────────────────────────────────────
# 3. Summary
# ─────────────────────────────────────────────────────
echo ""
echo "📋 Bootstrap manifests rendered:"
echo "   Cilium:  ${CILIUM_VERSION}"
echo "   ArgoCD:  ${ARGOCD_VERSION}"
echo ""
echo "   Files:"
ls -lh "${MANIFESTS_DIR}"/*.yaml 2>/dev/null || true
ls -lh "${MANIFESTS_DIR}"/*.tftpl 2>/dev/null || true
echo ""
echo "💡 Commit these files to the repository."
echo "   Re-run this script when upgrading Cilium or ArgoCD versions."
