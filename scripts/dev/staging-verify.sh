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

# Bounded wait, not an instant assertion. `task up` returns when OpenTofu is
# done, which is BEFORE the last workers finish joining and Cilium finishes
# rolling — measured 2026-08-14 on Scaleway, where this failed the run with "2
# node(s) not Ready" on a cluster that was healthy a minute later. The bound is
# what keeps it a check: a node that never joins still fails, it just fails after
# five minutes instead of instantly.
for _ in $(seq 1 30); do
  NOT_READY="$(kubectl get nodes --no-headers 2>/dev/null | grep -cvw Ready || true)"
  TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  [ "${NOT_READY:-1}" -eq 0 ] && [ "${TOTAL:-0}" -gt 0 ] && break
  sleep 10
done
if [ "${NOT_READY:-1}" -ne 0 ] || [ "${TOTAL:-0}" -eq 0 ]; then
  kubectl get nodes >&2 || true
  fail "${NOT_READY} node(s) still not Ready after 5 minutes"
fi
ok "$TOTAL node(s) Ready"

# --- The CNI is real ----------------------------------------------------------
# Named rather than counted: an empty selector counts zero and passes.
CILIUM="$(kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
[ "$CILIUM" -gt 0 ] || fail "no Cilium pod running — check the rendered manifest, not the apply"
ok "Cilium running on $CILIUM node(s)"

# --- Flux converged -----------------------------------------------------------
# Two defects lived here, both found the first time this ran on a real cluster
# (2026-08-14, Scaleway):
#
#   1. It reconciled `kustomization/flux-system`, which this stack does not
#      create — the root is the one the bootstrap manifest installs, named after
#      the project. Reconciling an object that does not exist fails every time,
#      so this check could never have passed anywhere.
#   2. It then demanded that every Kustomization be Ready at once, seconds after
#      bootstrap. The DAG is 35 deep and serialises on `dependsOn`; three minutes
#      in, `namespaces` was still reconciling and everything else was correctly
#      waiting for it. That is a healthy cluster, failed by an impatient check.
#
# So: wait for the DAG, bounded, and report what is still not Ready when the
# budget runs out. FLUX_READY_TIMEOUT is in seconds.
flux check >/dev/null 2>&1 || fail "flux check failed"

# Read the Ready CONDITION, not a column of `flux get`. That table has six
# columns once REVISION is filled and five while it is empty, so `$4` names READY
# only BEFORE a Kustomization applies and SUSPENDED after — a positional check
# that can only pass while nothing works. Third defect in this file found by
# running it (2026-08-14).
kustomization_status() {
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null
}

FLUX_READY_TIMEOUT="${FLUX_READY_TIMEOUT:-1500}"
deadline=$((SECONDS + FLUX_READY_TIMEOUT))
while :; do
  STATUS="$(kustomization_status)"
  TOTAL_K="$(printf '%s\n' "$STATUS" | grep -c . || true)"
  # An empty list must not read as converged: zero Kustomizations means Flux has
  # not created them yet, which is the opposite of done.
  STALLED="$(printf '%s\n' "$STATUS" | awk -F'\t' 'NF && $2 != "True" {print $1}')"
  [ "$TOTAL_K" -gt 0 ] && [ -z "$STALLED" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "still not Ready after ${FLUX_READY_TIMEOUT}s:" >&2
    printf '%s\n' "$STALLED" | sed 's/^/  /' >&2
    fail "$(printf '%s\n' "$STALLED" | grep -c .) of ${TOTAL_K} Kustomizations not Ready"
  fi
  sleep 15
done
ok "all $TOTAL_K Flux Kustomizations Ready"

# A SUSPENDED Kustomization keeps whatever Ready condition it had when it was
# suspended, so the loop above passes it happily while nothing reconciles it any
# more. `rolling-replace` suspends the one owning the CNPG clusters for the
# duration of a roll and resumes it in its exit trap — if that trap ever does not
# run, this is what says so instead of a green run over a frozen DAG.
SUSPENDED="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
  -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null || true)"
[ -z "$SUSPENDED" ] || fail "Kustomization(s) suspended, so their Ready status is stale: ${SUSPENDED}"
ok "no Kustomization is suspended"

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
