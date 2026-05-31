#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Register a spoke cluster in ArgoCD (management cluster hub)
#
# Usage:
#   ./scripts/register-spoke.sh <cluster-name> <provider>
#   task register-spoke CLUSTER=openaether-ovh-prod PROVIDER=ovh
#
# Prerequisites:
#   - KUBECONFIG_MANAGEMENT set (or defaults to ~/.kube/config)
#   - tofu output kubeconfig for the spoke cluster available
#   - kubectl pointing to the management cluster
# ==============================================================================
set -euo pipefail

CLUSTER="${1:-${CLUSTER:-}}"
PROVIDER="${2:-${PROVIDER:-}}"

if [[ -z "$CLUSTER" || -z "$PROVIDER" ]]; then
  echo "Usage: $0 <cluster-name> <provider>"
  echo "       CLUSTER=openaether-ovh-prod PROVIDER=ovh $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="${SCRIPT_DIR}/../infrastructure/opentofu"
MGMT_KUBECONFIG="${KUBECONFIG_MANAGEMENT:-${HOME}/.kube/config}"
ARGOCD_NS="management-gitops"

echo "🔗 Registering spoke cluster '${CLUSTER}' (provider: ${PROVIDER}) in ArgoCD..."

# 1. Retrieve spoke kubeconfig from OpenTofu output
echo "  → Retrieving kubeconfig from OpenTofu state..."
SPOKE_KUBECONFIG=$(mktemp)
trap "rm -f ${SPOKE_KUBECONFIG}" EXIT

pushd "${TOFU_DIR}" >/dev/null
tofu output -raw kubeconfig > "${SPOKE_KUBECONFIG}"
popd >/dev/null

# 2. Extract spoke cluster endpoint and CA from kubeconfig
SPOKE_SERVER=$(KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
SPOKE_CA=$(KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SPOKE_TOKEN=$(KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl -n kube-system get serviceaccount default -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")

# Use bearer token from kubeconfig if available (Talos generates one)
SPOKE_BEARER=$(KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || echo "")
if [[ -z "${SPOKE_BEARER}" ]]; then
  # Fallback: create a service account on the spoke cluster for ArgoCD
  KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
  sleep 3
  SPOKE_BEARER=$(KUBECONFIG="${SPOKE_KUBECONFIG}" kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
fi

# 3. Create ArgoCD cluster secret on the management cluster
echo "  → Creating cluster secret on management cluster..."
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${CLUSTER}
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
    openaether.io/managed: "true"
    openaether.io/role: workload
    openaether.io/provider: ${PROVIDER}
    openaether.io/cluster: ${CLUSTER}
type: Opaque
stringData:
  name: ${CLUSTER}
  server: ${SPOKE_SERVER}
  config: |
    {
      "bearerToken": "${SPOKE_BEARER}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${SPOKE_CA}"
      }
    }
EOF

echo "  ✅ Cluster '${CLUSTER}' registered in ArgoCD."
echo ""
echo "  ArgoCD will now deploy apps/overlays/workload-base/ to this cluster."
echo "  Monitor: kubectl --kubeconfig=${MGMT_KUBECONFIG} -n ${ARGOCD_NS} get applications"
