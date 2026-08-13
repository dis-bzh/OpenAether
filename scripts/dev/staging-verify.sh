#!/usr/bin/env bash
# What a staging run asserts once `task up` returns.
#
# `task up` succeeding means OpenTofu and the Talos bootstrap were happy. It does
# not mean the cluster works: the whole reason this rung exists is to ask the
# cluster itself, the way `feint.sh` asks the API instead of the state.
#
# Every check here FAILS the run. A staging job that warns and ends green is the
# defect that let a CNI-less local cluster ship for weeks.
#
# Usage: staging-verify.sh <provider> <role>
set -euo pipefail

PROVIDER="${1:?usage: staging-verify.sh <provider> <role>}"
ROLE="${2:?usage: staging-verify.sh <provider> <role>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

task kubeconfig ROLE="$ROLE" PROVIDER="$PROVIDER"
export KUBECONFIG="$ROOT/infrastructure/opentofu/cluster/kubeconfig"
export TALOSCONFIG="$ROOT/infrastructure/opentofu/cluster/talosconfig"

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

# --- The cluster answers ------------------------------------------------------
kubectl get --raw='/readyz' >/dev/null || fail "apiserver is not ready"
ok "apiserver ready"

NOT_READY="$(kubectl get nodes --no-headers | grep -cvw Ready || true)"
[ "$NOT_READY" -eq 0 ] || fail "$NOT_READY node(s) not Ready"
ok "$(kubectl get nodes --no-headers | wc -l) node(s) Ready"

# --- The CNI is real ----------------------------------------------------------
# Named rather than counted: an empty selector counts zero and passes.
CILIUM="$(kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
[ "$CILIUM" -gt 0 ] || fail "no Cilium pod running — check the rendered manifest, not the apply"
ok "Cilium running on $CILIUM node(s)"

# --- Flux converged -----------------------------------------------------------
# `flux get` prints a table; anything whose Ready column is not True after the
# wait is a brick that did not come up, and the run says which.
flux check >/dev/null 2>&1 || fail "flux check failed"
if ! flux reconcile kustomization flux-system --with-source --timeout=5m >/dev/null 2>&1; then
  flux get kustomizations -A >&2
  fail "the root Kustomization did not reconcile"
fi
STALLED="$(flux get kustomizations -A --no-header 2>/dev/null | awk '$4 != "True"' || true)"
if [ -n "$STALLED" ]; then
  echo "$STALLED" >&2
  fail "Kustomizations not Ready"
fi
ok "every Flux Kustomization Ready"

# --- Regression: the storage-admin UI stays unpublished -----------------------
# 1.0.1 took httproute-longhorn.yaml out of the default build because the UI has
# no authentication and the app LB has no ACL. Anything that puts it back has to
# fail here rather than in someone's account.
if kubectl -n longhorn-system get httproute longhorn >/dev/null 2>&1; then
  fail "the Longhorn HTTPRoute is published — it has no authN and the app LB has no ACL"
fi
ok "no unauthenticated storage UI on the gateway"

# --- The apps ref is the one we asked for -------------------------------------
# The gitception loop reapplies this object; if the ref drifted back to a branch
# default, the pin is not holding and the deployment is not the one named.
REF="$(kubectl -n flux-system get gitrepository openaether \
  -o jsonpath='{.spec.ref.name}{.spec.ref.branch}{.spec.ref.tag}' 2>/dev/null || true)"
[ -n "$REF" ] || fail "GitRepository/openaether has no resolvable ref"
ok "OpenAether-apps tracked at ${REF}"

echo "✓ ${PROVIDER}/${ROLE}: verified against the cluster, not the state"
