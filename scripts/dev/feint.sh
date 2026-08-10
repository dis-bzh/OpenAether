#!/usr/bin/env bash
# Drive a local Feint emulator (Scaleway / Outscale APIs, no account, no bill).
#
# What the emulated lane proves and what it does not: docs/emulated-cloud.md.
#
# Usage: feint.sh install|start|stop|status|guard [endpoint]
#        feint.sh plan|apply scaleway|outscale
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# renovate: datasource=github-releases depName=stephrobert/feint extractVersion=^v(?<version>.*)$
FEINT_VERSION="0.6.0"
FEINT_ENDPOINT="${FEINT_ENDPOINT:-http://127.0.0.1:4599}"
BIN_DIR="${FEINT_BIN_DIR:-$HOME/.local/bin}"

# --- The guard --------------------------------------------------------------
# Refuse anything that is not this machine. Every official cloud client falls
# back to the operator's stored credentials when the environment says nothing,
# so a redirection that quietly evaluates to empty does not fail — it bills.
# Feint's own repository shipped that bug and created a paying server with it.
guard_local() {
  case "${1:-}" in
    http://127.0.0.1:* | http://localhost:* | http://\[::1\]:*) return 0 ;;
    "") echo "✗ no endpoint given; refusing to run a client that would find its own" >&2 ;;
    *) echo "✗ endpoint ${1} is not local; this lane drives an emulator, never a real cloud" >&2 ;;
  esac
  exit 1
}

addr_of() { printf '%s' "${1#http://}"; }

# running answers whether the emulator is actually listening. `feint status`
# exits 0 whether or not it is, so the output is the only signal.
running() { feint status 2>/dev/null | grep -q '^running on'; }

# require_emulator fails a lane that has nothing to talk to.
#
# Without it these lanes go green with the emulator down — the plan lane makes
# almost no API calls, so it passes either way. A check that cannot fail is a
# check that measures nothing, and it hid a broken `feint-up` for exactly one run.
require_emulator() {
  running || {
    echo "✗ no emulator on $FEINT_ENDPOINT — run 'task feint-up' first" >&2
    exit 1
  }
}

# emulated_env clears every credential a provider could pick up on its own.
#
# Both lanes pin fake credentials in their provider blocks, but an ambient
# SCW_ACCESS_KEY still reaches the SDK and wins: leaving one set fails the run
# with "invalid access key format" at best, and at worst means a lane nobody can
# prove ran without credentials. The point of this lane is that none is needed,
# so none may be in scope.
emulated_env() {
  unset SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_ORGANIZATION_ID
  unset SCW_DEFAULT_REGION SCW_DEFAULT_ZONE SCW_API_URL SCW_PROFILE
  unset OSC_ACCESS_KEY OSC_SECRET_KEY OSC_REGION OUTSCALE_ACCESS_KEY_ID OUTSCALE_SECRET_KEY
  export TF_DATA_DIR=.terraform-feint TF_IN_AUTOMATION=1 TF_INPUT=0
}

# --- Commands ---------------------------------------------------------------
install_feint() {
  if command -v feint >/dev/null 2>&1 && [ "$(feint version)" = "v${FEINT_VERSION}" ]; then
    echo "feint v${FEINT_VERSION} already installed"
    return 0
  fi
  local base asset tmp
  base="https://github.com/stephrobert/feint/releases/download/v${FEINT_VERSION}"
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=feint-linux-amd64 ;;
    Linux-aarch64) asset=feint-linux-arm64 ;;
    Darwin-x86_64) asset=feint-darwin-amd64 ;;
    Darwin-arm64) asset=feint-darwin-arm64 ;;
    *) echo "✗ no published feint binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL -o "$tmp/$asset" "$base/$asset"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
  # --ignore-missing: the file lists every platform, and without it the check
  # fails on the ones we did not download — which reads like a bad binary.
  (cd "$tmp" && sha256sum -c checksums.txt --ignore-missing)
  mkdir -p "$BIN_DIR"
  install -m 0755 "$tmp/$asset" "$BIN_DIR/feint"
  echo "installed feint v${FEINT_VERSION} → $BIN_DIR/feint"
}

# plan_root runs `tofu plan` on the REAL cluster root against the emulator.
#
# That root declares a partial S3 backend, and `init -backend=false` then leaves
# `plan` refusing to run at all — which is why `task validate` stops at validate.
# An override file replaces the backend for the duration (OpenTofu: a backend
# block in an override file always takes precedence), and the trap removes it:
# left behind, it would silently send a real apply's state to a local file.
plan_root() {
  local provider="$1" root="$REPO_ROOT/infrastructure/opentofu/cluster"
  local example="$root/envs/feint-${provider}.tfvars.example"
  # Globals, not locals: the EXIT trap fires after this function has returned,
  # and a local would be unbound by then — the cleanup would die instead of run.
  override="$root/zz-feint-backend_override.tf"

  [ -f "$example" ] || { echo "✗ no such lane: $example" >&2; exit 1; }
  [ -e "$override" ] && { echo "✗ $override already exists; refusing to overwrite it" >&2; exit 1; }

  work="$(mktemp -d)"
  trap 'rm -f "${override:-}"; rm -rf "${work:-}"' EXIT

  cat > "$override" <<EOT
# Generated by scripts/dev/feint.sh, removed when it exits. If you are reading
# this in a working tree, a run died hard — delete it.
terraform {
  backend "local" {
    path = "$work/feint.tfstate"
  }
}
EOT
  cp "$example" "$work/feint.tfvars"

  emulated_env
  export TF_VAR_encryption_passphrase="feint-emulated-lane-passphrase-not-a-secret"

  cd "$root"
  tofu init -no-color -reconfigure
  tofu validate -no-color
  tofu plan -no-color -var-file="$work/feint.tfvars" -var "emulator_api_url=$FEINT_ENDPOINT"
  echo "✓ ${provider}: the real cluster root planned against the emulator, no credentials"
}

# machine_refs lists what apply created, read out of the outputs ONCE — before
# the destroy removes them. Reading them afterwards is how a post-destroy check
# ends up probing an empty list and passing without asking anything.
machine_refs() {
  local out
  out="$([ "$1" = scaleway ] && echo scaleway_paths || echo outscale_vm_ids)"
  tofu output -json "$out" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}

# count_live reports how many of those the emulator still serves. Asked of the
# API, never of the state: a destroy reporting success only means the provider
# believed what the delete answered.
count_live() {
  local provider="$1" refs="$2" live=0 ref
  [ -n "$refs" ] || { printf '0'; return; }
  while read -r ref; do
    [ -n "$ref" ] || continue
    if [ "$provider" = scaleway ]; then
      [ "$(curl -s -o /dev/null -w '%{http_code}' "${FEINT_ENDPOINT}${ref}")" = "200" ] && live=$((live + 1))
    else
      # Presence is not liveness on Outscale: a deleted VM stays readable as
      # "terminated", on the real API as on the emulator. Counting rows here
      # would make every destroy look like a failure.
      live=$((live + $(curl -s -X POST "${FEINT_ENDPOINT}/api/v1/ReadVms" \
        -H 'Content-Type: application/json' -d "{\"Filters\":{\"VmIds\":[\"$ref\"]}}" \
        | python3 -c 'import json,sys
dead = {"terminated", "shutting-down"}
print(sum(1 for v in json.load(sys.stdin).get("Vms", []) if v.get("State") not in dead))')))
    fi
  done <<< "$refs"
  printf '%s' "$live"
}

# apply_fixture drives the real create/read/update/delete cycle.
#
# `plan` alone proves only that the provider accepts an address and can read.
# The empty second plan is the actual assertion: it holds only if every attribute
# the provider sent comes back identical, which is where an invented or dropped
# field shows up.
apply_fixture() {
  local expected live rc refs
  # Globals, like `override` above: the EXIT trap fires after this function has
  # returned, and a local would be unbound by then.
  provider="$1"
  root="$REPO_ROOT/infrastructure/opentofu-feint"

  work="$(mktemp -d)"
  # Destroy on the error path too: an apply that dies half-way leaves resources
  # behind, and the next run then starts from a poisoned emulator.
  trap 'cd "${root:-}" 2>/dev/null && tofu destroy -no-color -auto-approve -var "target_provider=${provider:-}" -var "endpoint=$FEINT_ENDPOINT" >/dev/null 2>&1; rm -rf "${work:-}"' EXIT

  emulated_env
  cd "$root"
  local args=(-var "target_provider=$provider" -var "endpoint=$FEINT_ENDPOINT")

  tofu init -no-color
  tofu validate -no-color
  tofu apply -no-color -auto-approve "${args[@]}"

  expected=3 # control plane + worker + bastion, in both fixtures
  refs="$(machine_refs "$provider")"
  live="$(count_live "$provider" "$refs")"
  [ "$live" = "$expected" ] || { echo "✗ applied $expected machines, the API serves $live" >&2; exit 1; }
  echo "  ok: $live machines exist in the API, not just in the state"

  rc=0; tofu plan -no-color -detailed-exitcode "${args[@]}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "  ok: the second plan is empty — everything read back as it was sent" ;;
    2) tofu plan -no-color "${args[@]}" || true
       echo "✗ the applied state still plans a change: the API does not read back what was sent" >&2; exit 1 ;;
    *) echo "✗ the second plan errored (status $rc)" >&2; exit 1 ;;
  esac

  tofu destroy -no-color -auto-approve "${args[@]}"
  trap 'rm -rf "${work:-}"' EXIT
  # Same refs as before the destroy — the outputs are gone now, and re-reading
  # them here would ask the emulator about nothing at all.
  live="$(count_live "$provider" "$refs")"
  [ "$live" = "0" ] || { echo "✗ destroy reported success but the API still serves $live machines" >&2; exit 1; }
  echo "✓ ${provider}: apply / empty re-plan / destroy, confirmed against the API"
}

case "${1:-}" in
  install) install_feint ;;
  start)
    guard_local "$FEINT_ENDPOINT"
    command -v feint >/dev/null 2>&1 || install_feint
    # Idempotent: `feint start` refuses when one is already listening, and a
    # target you cannot run twice is a target nobody re-runs after a failure.
    # Matched on the output, not the exit code: `feint status` exits 0 either
    # way, so keying off it silently skipped the start and left every later
    # step running against nothing.
    running || feint start --addr "$(addr_of "$FEINT_ENDPOINT")"
    running || { echo "✗ the emulator did not come up on $FEINT_ENDPOINT" >&2; exit 1; }
    feint status
    ;;
  stop)
    # clean before stop: a stopped emulator keeps nothing, but a shared one left
    # running between lanes would carry the previous run's resources into the next.
    feint clean >/dev/null 2>&1 || true
    feint stop || true
    ;;
  status) feint status ;;
  guard) guard_local "${2:-$FEINT_ENDPOINT}" ;;
  plan)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    plan_root "${2:?usage: feint.sh plan scaleway|outscale}"
    ;;
  apply)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    apply_fixture "${2:?usage: feint.sh apply scaleway|outscale}"
    ;;
  *)
    echo "Usage: $(basename "$0") install|start|stop|status|guard [endpoint]" >&2
    echo "       $(basename "$0") plan|apply scaleway|outscale" >&2
    exit 1
    ;;
esac
