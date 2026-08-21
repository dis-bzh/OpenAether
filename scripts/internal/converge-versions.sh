#!/usr/bin/env bash
# Bring the RUNNING fleet to the versions the config pins — the half of
# `cluster-up` that OpenTofu cannot do.
#
# `cluster-up` writes the pinned installer image into the machine config and asks
# NO node to upgrade, so a bumped pin lands a machine config and leaves the fleet
# a version behind, with an empty plan behind it. Editing the tfvars IS the
# decision to upgrade; this is what makes the command reach it.
#
# NOT cluster-upgrade.sh. That script fails BY DESIGN when the fleet already
# matches both targets — exactly the state cluster-up leaves behind — so folding
# it in would turn every ordinary bring-up into a hard failure. This reuses the
# roll it calls, and nothing else.
#
# --check reports and rolls nothing. cluster-up runs it BEFORE the approval
# question, so the operator says yes to a journey that includes the roll instead
# of discovering it afterwards. `ignore_changes` on the image attribute keeps the
# roll out of the OpenTofu plan entirely, so the plan cannot show it.
#
# Usage: converge-versions.sh <provider> <role> <key> [--check]
set -euo pipefail

PROVIDER="${1:?usage: converge-versions.sh <provider> <role> <key> [--check]}"
ROLE="${2:?usage: converge-versions.sh <provider> <role> <key> [--check]}"
KEY="${3:-$HOME/.ssh/id_ed25519}"; KEY="${KEY/#\~/$HOME}"
CHECK_ONLY=0; [ "${4:-}" = --check ] && CHECK_ONLY=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
TFVARS="$CLUSTER_DIR/envs/${ROLE}-${PROVIDER}.tfvars"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"

fail() { echo "✗ $*" >&2; exit 1; }

want_talos="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" talos_version)"
want_k8s="$(oa_pinned_version "$CLUSTER_DIR" "$TFVARS" kubernetes_version)"
have_talos="$(oa_fleet_versions '.status.nodeInfo.osImage')"
have_k8s="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"

# Nothing pinned anywhere is a legitimate configuration, not a drift.
if [ -z "$want_talos" ] && [ -z "$want_k8s" ]; then
  echo "  no talos_version or kubernetes_version pinned — nothing to converge toward"
  exit 0
fi

# No cluster to ask. Before the apply that is the normal case and says nothing
# useful; after it, a fleet we cannot read is a fleet we cannot claim anything
# about — and claiming it anyway is the defect this whole file exists to close.
if [ -z "$have_talos" ] && [ -z "$have_k8s" ]; then
  [ "$CHECK_ONLY" = 1 ] && exit 0
  fail "the apiserver named no nodes, so the running versions are UNKNOWN.
  Nothing was rolled and nothing can be promised about this fleet.
  Check the cluster, then: task cluster-verify PROVIDER=${PROVIDER} ROLE=${ROLE}"
fi

drift=0
[ -n "$want_talos" ] && [ "$have_talos" != "$want_talos" ] && drift=1
[ -n "$want_k8s" ]   && [ "$have_k8s"   != "$want_k8s"   ] && drift=1

if [ "$drift" = 0 ]; then
  echo "✓ the fleet already runs the pinned versions (Talos ${have_talos}, Kubernetes ${have_k8s}) — nothing to roll"
  exit 0
fi

echo "▶ the fleet does not match the pin:"
[ "$have_talos" = "$want_talos" ] || echo "    Talos      running ${have_talos:-?} → pinned ${want_talos}"
[ "$have_k8s"   = "$want_k8s"   ] || echo "    Kubernetes running ${have_k8s:-?} → pinned ${want_k8s}"

if [ "$CHECK_ONLY" = 1 ]; then
  echo "    Approving below also approves rolling every node, one at a time, to close this."
  exit 0
fi

# A Kubernetes-only move must NOT reboot nodes, and a Talos move must. Both are
# what --upgrade already means to the roll; control planes first, because a
# worker's upgrade drains against a healthy control plane.
task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --cp-only --upgrade
task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --workers-only --upgrade

# Ask again. The roll reporting success is the client talking; this is the fleet.
got_talos="$(oa_fleet_versions '.status.nodeInfo.osImage')"
got_k8s="$(oa_fleet_versions '.status.nodeInfo.kubeletVersion')"
[ -n "$got_talos" ] || fail "after the roll the apiserver named no nodes — nothing was verified"
[ -z "$want_talos" ] || [ "$got_talos" = "$want_talos" ] ||
  fail "after the roll the fleet runs Talos ${got_talos}, the config pins ${want_talos}"
[ -z "$want_k8s" ] || [ "$got_k8s" = "$want_k8s" ] ||
  fail "after the roll the fleet runs Kubernetes ${got_k8s}, the config pins ${want_k8s}"
echo "✓ converged: every node runs Talos ${got_talos}, Kubernetes ${got_k8s}"
