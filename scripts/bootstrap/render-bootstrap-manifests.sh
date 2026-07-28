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
#   ./scripts/bootstrap/render-bootstrap-manifests.sh --check   # writes NOTHING: checks
#                                                     # that the committed artifacts
#                                                     # match the generator
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for --check (render into a throwaway directory, then diff).
# ⚠️ TWO levels: this script lives in scripts/bootstrap/. With a single `..`
# it wrote into scripts/infrastructure/… — a PHANTOM directory created by the
# `mkdir -p` below and never read by OpenTofu. `task render-manifests`
# therefore appeared to work while NEVER regenerating the committed
# artifacts: that is the origin of their drift away from the generator
# (observed 2026-07-27).
MANIFESTS_DIR="${OPENAETHER_MANIFESTS_DIR:-${SCRIPT_DIR}/../../infrastructure/opentofu/cluster/bootstrap-manifests}"

# Mode: production (default) or local Docker testing
LOCAL_MODE=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_MODE=true
  shift
fi

# ─────────────────────────────────────────────────────────────
# --check: anti-drift guardrail
#
# A generated artifact can diverge from its generator SILENTLY — it happened:
# the committed cilium*.yaml carried three `--set` flags missing from this
# script, so a plain `task render-manifests` broke Istio ambient with nothing
# reporting it. This mode replays the render into a throwaway dir and compares.
#
# Checks ONLY the manifests WE generate (cilium.yaml, cilium-local.yaml).
# flux-install.yaml is an upstream download: its evolution is a different
# signal (a new Flux release), not a drift in our configuration.
# ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
  command -v diff >/dev/null 2>&1 || { echo "✗ diff requis" >&2; exit 1; }
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "🔍 Vérification des artefacts committés contre le générateur…"
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" >/dev/null
  OPENAETHER_MANIFESTS_DIR="$tmp" OPENAETHER_SKIP_FLUX=1 "$0" --local >/dev/null
  # helm's raw render carries trailing whitespace; the committed artifact has
  # been through the pre-commit hooks (`trim trailing whitespace`,
  # `fix end of files`). Comparing them as-is would keep the check permanently
  # red — so we normalise BOTH sides, exactly like the hook does.
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
  # ⚠️ socketLB.enabled=true is MANDATORY here, even though kubeProxyReplacement
  # is false. Without it the chart emits `bpf-lb-sock: "false"`, which makes
  # `bpf-lb-sock-hostns-only` INOPERATIVE: hostNetwork pods (kube-apiserver)
  # can then no longer reach ClusterIPs and Flux dry-runs time out on the
  # webhooks. The fix lived in the committed artifact, not in this script —
  # so regenerating reintroduced the bug (caught by --check on 2026-07-27).
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
  # ⚠️ Both settings are REQUIRED by Istio ambient (apps/base/istio) — do not
  # remove them without removing the mesh, or istio-cni never becomes Ready:
  #  - cni.exclusive=false: otherwise Cilium rewrites 05-cilium.conflist in a
  #    loop and strips the chained istio-cni plugin ("conflicting component
  #    constantly reverting our work") → /readyz 503 → Helm install timeout →
  #    ztunnel, services-gateway and istio-authorizationpolicies stuck in turn;
  #  - socketLB.hostNamespaceOnly=true: without it the socket-LB short-circuits
  #    the ambient redirection for host-network processes.
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

# helm leaves trailing whitespace; the `trim trailing whitespace` pre-commit
# hook strips it at commit time. Without normalising HERE, every render dirties
# the working tree and the committed artifact can never be identical to the
# render — which forced --check to compare "modulo whitespace".
sed -i 's/[[:space:]]*$//' "${CILIUM_OUTPUT}"

# ─────────────────────────────────────────────────────
# 2. Download Flux install manifest
# ─────────────────────────────────────────────────────
# ⚠️ DOWNLOAD IS DELIBERATELY OPT-IN (OPENAETHER_REFRESH_FLUX=1).
#
# Two reasons, both observed on 2026-07-27:
#  1. without FLUX_VERSION the URL is `releases/latest` — a plain
#     `task render-manifests` BUMPED Flux to the latest published version,
#     with nothing asking for it and nothing reporting it;
#  2. the committed artifact is NOT a stock upstream install.yaml: it carries
#     one extra controller, `source-watcher` (7 Deployments / 15 CRDs instead
#     of 6 / 14). Overwriting it with the standard install.yaml would REMOVE
#     that controller from the bootstrap.
# To regenerate it knowingly: pin FLUX_VERSION *and* rebuild the component set
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
