#!/usr/bin/env bash
# Upgrade Kubernetes, then Talos, on a running staging cluster — and measure the
# interruption instead of asserting there was none.
#
# 1.0.0 shipped the upgrade path unverified. It was then proven by hand on all
# three clouds (2026-08-13) and has had no unattended coverage since, which is
# the same position 1.0.0 was in.
#
# WHERE THE TARGET COMES FROM. Not from upstream's newest release: from
# `cluster/variables.tf`, the pair this repository actually ships. The staging
# tfvars is expected to pin a patch BELOW it, so a run upgrades toward what a
# reader deploying today would land on, and Renovate bumping the defaults is what
# keeps the lane fed. Override with UPGRADE_TALOS_TO / UPGRADE_K8S_TO.
#
# NOTHING HERE RETRIES. The first apply after a `talos_version` bump is known to
# fail on OVH and Outscale (backlog: "Provider produced inconsistent final plan").
# A retry would turn that defect into a green run, which is how it survived this
# long.
#
# DRY_RUN=1 resolves the versions and rewrites a COPY of the tfvars, then stops
# before the first task. It needs no cluster and no credentials, and it is what
# makes the version arithmetic below testable rather than first exercised on a
# paying account.
#
# Usage: staging-upgrade.sh <provider> <role> [ssh-key]
set -euo pipefail

PROVIDER="${1:?usage: staging-upgrade.sh <provider> <role> [ssh-key]}"
ROLE="${2:?usage: staging-upgrade.sh <provider> <role> [ssh-key]}"
KEY="${3:-$HOME/.ssh/id_ed25519}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TFVARS="$ROOT/infrastructure/opentofu/cluster/envs/${ROLE}-${PROVIDER}.tfvars"

# The apiserver is allowed to blink while a control plane restarts — the hand-run
# on 2026-08-13 lost 3 probe seconds to it. This is a ceiling on that blink, not
# a claim of zero: raise it only with a measurement that says why.
MAX_PROBE_FAILS="${MAX_PROBE_FAILS:-15}"

export KUBECONFIG="$ROOT/infrastructure/opentofu/cluster/kubeconfig"

fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

[ -f "$TFVARS" ] || fail "no $TFVARS"

if [ "${DRY_RUN:-}" = "1" ]; then
  DRY_COPY="$(mktemp)"
  cp "$TFVARS" "$DRY_COPY"
  TFVARS="$DRY_COPY"
  trap 'rm -f "$DRY_COPY"' EXIT
fi

# --- Where we are, and where we are going -------------------------------------

tfvar_get() { # <key> — the tfvars pin, or cluster/variables.tf's default
  local v
  v="$(grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" | head -1 |
    sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')"
  [ -n "$v" ] || v="$(awk "/variable \"$1\"/,/^}/" "$ROOT/infrastructure/opentofu/cluster/variables.tf" |
    sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
  printf '%s' "$v"
}

tfvar_set() { # <key> <value> — replace the pin, or add one if the file has none
  local key="$1" value="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS"; then
    sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\1\"$value\"|" "$TFVARS"
  else
    printf '\n%s = "%s"\n' "$key" "$value" >>"$TFVARS"
  fi
  [ "$(tfvar_get "$key")" = "$value" ] || fail "could not set $key to $value in $TFVARS"
}

default_of() { # <key> — cluster/variables.tf only, ignoring the tfvars
  awk "/variable \"$1\"/,/^}/" "$ROOT/infrastructure/opentofu/cluster/variables.tf" |
    sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1
}

TALOS_FROM="$(tfvar_get talos_version)"
K8S_FROM="$(tfvar_get kubernetes_version)"
TALOS_TO="${UPGRADE_TALOS_TO:-$(default_of talos_version)}"
K8S_TO="${UPGRADE_K8S_TO:-$(default_of kubernetes_version)}"

echo "  Talos      ${TALOS_FROM} → ${TALOS_TO}"
echo "  Kubernetes ${K8S_FROM} → ${K8S_TO}"

if [ "$TALOS_FROM" = "$TALOS_TO" ] && [ "$K8S_FROM" = "$K8S_TO" ]; then
  # Loud, and a failure — not a skip. A lane that quietly exercises nothing is
  # indistinguishable from a lane that passed, and this one costs money to run.
  fail "the staging tfvars already pins both target versions, so this run would
  upgrade nothing. Pin a patch below cluster/variables.tf in STAGING_TFVARS_B64,
  or pass UPGRADE_TALOS_TO / UPGRADE_K8S_TO."
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  # Guarded exactly as the real path is, or the dry run would show a rewrite the
  # real run never performs.
  if [ "$K8S_FROM" != "$K8S_TO" ]; then tfvar_set kubernetes_version "$K8S_TO"; fi
  if [ "$TALOS_FROM" != "$TALOS_TO" ]; then tfvar_set talos_version "$TALOS_TO"; fi
  echo "--- what the tfvars would become ---"
  diff -u "$ROOT/infrastructure/opentofu/cluster/envs/${ROLE}-${PROVIDER}.tfvars" "$TFVARS" || true
  ok "dry run: versions resolved and the tfvars rewrite is well-formed"
  exit 0
fi

# --- The probe ----------------------------------------------------------------
# One second apart, against the endpoint in the kubeconfig — never a tunnel to a
# single node, which measures the node we are deliberately taking away.

PROBE_LOG="$(mktemp)"
probe() {
  while :; do
    if kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; then
      echo ok
    else
      echo FAIL
    fi
    sleep 1
  done >>"$PROBE_LOG"
}
probe &
PROBE_PID=$!
# When the sampling started, so report_probe can tell "few samples because the
# step was quick" from "few samples because the probe is dead".
PROBE_STARTED=$SECONDS
# shellcheck disable=SC2064  # PROBE_PID must expand now, not at trap time
trap "kill $PROBE_PID 2>/dev/null || true; rm -f '$PROBE_LOG'" EXIT

# The assertion is about the LONGEST CONSECUTIVE outage, not the total number of
# failed samples — those are different claims and only the first matches the
# message this used to print ("unreachable for ~Ns"). Eighteen one-second blips
# spread over a control-plane roll is an HA cluster working as designed; eighteen
# in a row is the API being down. Counting them the same way cannot tell a
# healthy rolling restart from a total outage. Measured 2026-08-16: OVH 4 fails
# in 31 samples, Scaleway 18 in 59, on identical health-check settings.
#
# The log is also KEPT when the assertion trips: the old trap deleted the only
# evidence at exactly the moment someone would need it.
report_probe() {
  local fails total longest keep
  fails="$(grep -c FAIL "$PROBE_LOG" || true)"
  total="$(wc -l <"$PROBE_LOG")"
  # An EMPTY log satisfies "longest outage 0s ≤ 15s". If the probe died at the
  # start — no kubeconfig yet, no kubectl on PATH — the assertion below concludes
  # from no evidence and the run is called clean.
  #
  # The floor is RELATIVE to how long the probe has been alive, not a fixed count:
  # the probe samples about once a second, so expect roughly one sample per second
  # and demand a quarter of that. A fixed floor would fail a legitimately fast
  # step, which is the mirror defect — a guard written for the pathological case
  # firing on the normal one. Inert below 30s for the same reason.
  local elapsed=$(( SECONDS - ${PROBE_STARTED:-0} ))
  if [ "$elapsed" -ge 30 ] && [ "$total" -lt $(( elapsed / 4 )) ]; then
    fail "the probe wrote ${total} sample(s) in ${elapsed}s — it is not measuring, so no claim about the outage can be made"
  fi
  longest="$(awk '/FAIL/{r++; if (r>m) m=r; next} {r=0} END{print m+0}' "$PROBE_LOG")"
  echo "  probe: ${fails} FAIL in ${total} samples (~1s apart), longest outage ${longest}s"
  [ "$longest" -le "$MAX_PROBE_FAILS" ] && return 0
  keep="${PROBE_LOG}.kept"
  cp "$PROBE_LOG" "$keep" 2>/dev/null || true
  fail "the API was unreachable for ${longest}s in a row, over the ${MAX_PROBE_FAILS}s this lane allows (samples kept in ${keep})"
}

# --- Kubernetes first: no reboot, so it isolates the control-plane roll --------

if [ "$K8S_FROM" != "$K8S_TO" ]; then
  echo "--- Kubernetes ${K8S_FROM} → ${K8S_TO} ---"
  tfvar_set kubernetes_version "$K8S_TO"
  task infra ROLE="$ROLE" PROVIDER="$PROVIDER"

  # Talos reconciles the static pods and the kubelets; the node's reported
  # version is the observable end of that, and it is not instant.
  echo "waiting for every kubelet to report ${K8S_TO}"
  for _ in $(seq 1 60); do
    # COUNT THE NODES, not just the stale ones. `grep -cvx` over the output of a
    # kubectl that answered nothing returns 0, which reads exactly like "every
    # kubelet is on the target" — a dead apiserver used to pass this.
    SEEN="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null |
      grep -c . || true)"
    STALE="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null |
      grep -cvx "$K8S_TO" || true)"
    [ "$SEEN" -gt 0 ] && [ "$STALE" -eq 0 ] && break
    sleep 10
  done
  [ "${SEEN:-0}" -gt 0 ] || fail "the apiserver reported no nodes at all — nothing was verified, and this is not an upgrade that succeeded"
  [ "${STALE:-1}" -eq 0 ] || fail "${STALE} kubelet(s) still not on ${K8S_TO} after 10 minutes"
  ok "every kubelet on ${K8S_TO} (${SEEN} node(s) seen)"
  report_probe
fi

# --- Then Talos, in place ------------------------------------------------------

if [ "$TALOS_FROM" != "$TALOS_TO" ]; then
  echo "--- Talos ${TALOS_FROM} → ${TALOS_TO} ---"

  # The nodes ignore their image attribute, but the image DATA SOURCE still has
  # to resolve, and it derives its name from talos_version. Without this the
  # plan fails on an image the account does not have.
  task talos-image PROVIDER="$PROVIDER" VERSION="$TALOS_TO" ENSURE=1

  tfvar_set talos_version "$TALOS_TO"
  task infra ROLE="$ROLE" PROVIDER="$PROVIDER"

  # One node at a time, health-gated between each; control planes first because
  # a worker's upgrade needs a healthy control plane to drain against.
  # --yes: there is no terminal here, and without it rolling-replace stops at its
  # confirmation prompt and exits 1 — which is how an unattended lane discovers
  # that a script it depends on was only ever run by hand.
  task rolling-replace PROVIDER="$PROVIDER" KEY="$KEY" -- --cp-only --upgrade --yes
  task rolling-replace PROVIDER="$PROVIDER" KEY="$KEY" -- --workers-only --upgrade --yes

  # Same trap as the kubelet count above: with no nodes returned, `grep -cv`
  # answers 0 and a dead cluster reports a clean Talos upgrade.
  OSIMAGES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  RUNNING="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null |
    grep -cv "$TALOS_TO" || true)"
  [ "$OSIMAGES" -gt 0 ] || fail "the apiserver reported no nodes at all after the Talos roll — nothing was verified"
  [ "$RUNNING" -eq 0 ] || fail "${RUNNING} node(s) are not running Talos ${TALOS_TO}"
  ok "every node on Talos ${TALOS_TO} (${OSIMAGES} node(s) seen)"
  report_probe
fi

# --- What a clean upgrade leaves behind ----------------------------------------

# Zero destroys. A plan that wants to replace nodes means the boot image and the
# running version have disagreed — that plan would take the cluster down.
# See modules/providers/provider-contract.md § "Node image drift".
task plan ROLE="$ROLE" PROVIDER="$PROVIDER" STRICT=1 ||
  fail "the plan is not empty after the upgrade — read provider-contract.md § Node image drift before re-running anything"
ok "plan empty after the upgrade"

# Verify what this cluster ACTUALLY is, not what the upgrade lane assumes it is.
# staging-verify.sh waits for 35 Flux Kustomizations; a 1.0.0 cluster is Talos
# and Cilium and has none, so calling it unconditionally failed an upgrade that
# had just succeeded on every count — nodes on the target version, three seconds
# of API outage, empty plan. Asked of the cluster rather than of a variable,
# because that is the only source that cannot drift from reality.
if kubectl get namespace flux-system >/dev/null 2>&1; then
  "$ROOT/scripts/dev/staging-verify.sh" "$PROVIDER" "$ROLE"
else
  ok "no flux-system — verifying against the infrastructure floor"
  "$ROOT/scripts/dev/infra-verify.sh" "$PROVIDER" "$ROLE"
fi

report_probe
echo "✓ ${PROVIDER}/${ROLE}: upgraded ${TALOS_FROM}→${TALOS_TO} / ${K8S_FROM}→${K8S_TO}, in place"
