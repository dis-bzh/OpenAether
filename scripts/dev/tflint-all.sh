#!/usr/bin/env bash
# Lint every OpenTofu directory in the tree with ONE tflint config.
#
# The config used to live in cluster/, and `tflint --recursive` resolves
# .tflint.hcl per directory: thirteen of the fourteen directories holding .tf
# were linted with no config at all — no preset, no naming or documentation
# rules — and reported exit 0. Hoisting the file alone does NOT fix that, it
# only moves the blind spot: a parent .tflint.hcl is never found either. The
# config has to be named explicitly, and TFLINT_CONFIG_FILE is the only form
# that survives the chdir tflint does per directory (a relative -c is resolved
# against each subdirectory and fails to open).
#
# Which leaves the failure this repository keeps meeting: lose the variable and
# tflint drops back to its default rules, finds fewer things, and still exits 0
# on a clean tree. Nothing in `tflint --version` tells the two apart. So the
# config is proven loaded first, on a fixture that must draw a rule ONLY this
# config enables — by rule NAME, never by exit code: the default rules reject
# that fixture too, so the code alone proves nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TREE="$ROOT/infrastructure/opentofu"
CONFIG="$TREE/.tflint.hcl"
CANARY_RULE="terraform_documented_variables"

[[ -f "$CONFIG" ]] || { echo "✗ no tflint config at $CONFIG" >&2; exit 1; }
grep -q "$CANARY_RULE" "$CONFIG" || {
  echo "✗ $CANARY_RULE is gone from the config — this script proves nothing without it" >&2
  exit 1
}
export TFLINT_CONFIG_FILE="$CONFIG"

canary="$(mktemp -d)"
trap 'rm -rf "$canary"' EXIT
printf 'variable "undocumented_canary" {\n  type = string\n}\n' > "$canary/main.tf"
# Captured, not piped: tflint exits 2 on the fixture (the default rules reject
# it too), and under `pipefail` that non-zero would defeat the grep's verdict.
canary_out="$(tflint --chdir="$canary" 2>&1 || true)"
if ! grep -q "$CANARY_RULE" <<<"$canary_out"; then
  echo "✗ $CANARY_RULE never fired — the config was not loaded" >&2
  echo "  (TFLINT_CONFIG_FILE=$TFLINT_CONFIG_FILE)" >&2
  exit 1
fi

[[ "${TFLINT_INIT:-0}" == "1" ]] && tflint --chdir="$TREE" --init

tflint --chdir="$TREE" --recursive
echo "✓ tflint: every directory linted, $CANARY_RULE proven live"
