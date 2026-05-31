#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Local Stack Validation
#
# Validates the full stack without requiring cloud credentials:
#   1. OpenTofu: fmt, validate, unit tests (mock providers)
#   2. Kustomize: build all overlays
#   3. Talos: generate and validate machine configs locally
#   4. YAML: lint
#   5. Summary
#
# Usage:
#   ./scripts/test-local-stack.sh [--fast]   # --fast skips talosctl gen
#
# Prerequisites: tofu, kubectl (kustomize), talosctl, yamllint
# ==============================================================================
set -euo pipefail

FAST="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
TOFU_DIR="${ROOT_DIR}/infrastructure/opentofu"
PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check() {
  local name="$1"
  shift
  printf "  %-55s" "${name}"
  if "$@" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ PASS${NC}"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}✗ FAIL${NC}"
    FAIL=$((FAIL + 1))
    # Run again to show the error
    "$@" 2>&1 | sed 's/^/    /' || true
  fi
}

skip() {
  local name="$1"
  local reason="$2"
  printf "  %-55s" "${name}"
  echo -e "${YELLOW}⊘ SKIP${NC} (${reason})"
  SKIP=$((SKIP + 1))
}

section() {
  echo ""
  echo -e "${BLUE}══ $1 ══${NC}"
}

# ==============================================================================
# 1. OpenTofu
# ==============================================================================
section "1. OpenTofu"

check "fmt check" tofu fmt -check -recursive "${TOFU_DIR}"
check "validate" bash -c "cd '${TOFU_DIR}' && AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock TF_VAR_encryption_passphrase='mock-passphrase-for-validation-only-123' tofu validate"
check "unit tests (scaleway)" bash -c "cd '${TOFU_DIR}' && AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock TF_VAR_encryption_passphrase='mock-passphrase-for-validation-only-123' tofu test -filter=tests/scaleway.tftest.hcl"
check "unit tests (talos-config)" bash -c "cd '${TOFU_DIR}' && AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock TF_VAR_encryption_passphrase='mock-passphrase-for-validation-only-123' tofu test -filter=tests/talos-config.tftest.hcl"
check "unit tests (provider-contract)" bash -c "cd '${TOFU_DIR}' && AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock TF_VAR_encryption_passphrase='mock-passphrase-for-validation-only-123' tofu test -filter=tests/provider-contract.tftest.hcl"

# ==============================================================================
# 2. Kustomize — Build all overlays
# ==============================================================================
section "2. Kustomize Overlays"

OVERLAYS=(
  "apps/bootstrap/overlays/prod"
  "apps/bootstrap/overlays/local"
  "apps/overlays/management"
  "apps/overlays/workload-base"
  "apps/overlays/local"
  "apps/overlays/prod"
)

for overlay in "${OVERLAYS[@]}"; do
  if [[ -d "${ROOT_DIR}/${overlay}" ]]; then
    check "build: ${overlay}" kubectl kustomize "${ROOT_DIR}/${overlay}"
  else
    skip "build: ${overlay}" "directory not found"
  fi
done

# ==============================================================================
# 3. Talos — Generate and validate machine configs locally
# ==============================================================================
section "3. Talos Config Generation (local)"

if [[ "${FAST}" == "--fast" ]]; then
  skip "talosctl gen config" "--fast flag"
  skip "talosctl validate (controlplane)" "--fast flag"
  skip "talosctl validate (worker)" "--fast flag"
elif ! command -v talosctl &>/dev/null; then
  skip "talosctl gen config" "talosctl not found"
  skip "talosctl validate (controlplane)" "talosctl not found"
  skip "talosctl validate (worker)" "talosctl not found"
else
  TALOS_TMP=$(mktemp -d)
  trap "rm -rf ${TALOS_TMP}" EXIT

  # Generate a minimal Talos config for testing
  check "talosctl gen secrets" talosctl gen secrets --output-file "${TALOS_TMP}/secrets.yaml"

  check "talosctl gen config" bash -c "
    talosctl gen config \
      --with-secrets '${TALOS_TMP}/secrets.yaml' \
      --output '${TALOS_TMP}' \
      --output-types controlplane,worker \
      'test-cluster' 'https://127.0.0.1:6443' 2>/dev/null
  "

  if [[ -f "${TALOS_TMP}/controlplane.yaml" ]]; then
    check "talosctl validate (controlplane)" talosctl validate \
      --config "${TALOS_TMP}/controlplane.yaml" \
      --mode metal
  else
    skip "talosctl validate (controlplane)" "config not generated"
  fi

  if [[ -f "${TALOS_TMP}/worker.yaml" ]]; then
    check "talosctl validate (worker)" talosctl validate \
      --config "${TALOS_TMP}/worker.yaml" \
      --mode metal
  else
    skip "talosctl validate (worker)" "config not generated"
  fi

  # Check key fields in the generated configs
  if [[ -f "${TALOS_TMP}/controlplane.yaml" ]]; then
    check "controlplane: kube-proxy disabled" bash -c "
      grep -q 'disabled: true' '${TALOS_TMP}/controlplane.yaml'
    "
    check "controlplane: cni name not flannel" bash -c "
      ! grep -q 'name: flannel' '${TALOS_TMP}/controlplane.yaml'
    "
  fi
fi

# ==============================================================================
# 4. YAML Lint
# ==============================================================================
section "4. YAML Lint"

if command -v yamllint &>/dev/null; then
  check "yamllint apps/" yamllint -c "${ROOT_DIR}/infrastructure/.yamllint" "${ROOT_DIR}/apps/"
  check "yamllint infrastructure/" yamllint -c "${ROOT_DIR}/infrastructure/.yamllint" "${ROOT_DIR}/infrastructure/opentofu/bootstrap-manifests/"
else
  skip "yamllint" "yamllint not found (pip install yamllint)"
fi

# ==============================================================================
# 5. Pre-commit checks (if available)
# ==============================================================================
section "5. Pre-commit"

if command -v pre-commit &>/dev/null && [[ -f "${ROOT_DIR}/.pre-commit-config.yaml" ]]; then
  check "pre-commit (staged files)" pre-commit run --all-files
else
  skip "pre-commit" "not installed or no config"
fi

# ==============================================================================
# Summary
# ==============================================================================
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "════════════════════════════════════════════════"
echo -e "  Total: ${TOTAL}  |  ${GREEN}Pass: ${PASS}${NC}  |  ${RED}Fail: ${FAIL}${NC}  |  ${YELLOW}Skip: ${SKIP}${NC}"
echo "════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo -e "${RED}✗ ${FAIL} check(s) failed. Fix before committing.${NC}"
  exit 1
else
  echo ""
  echo -e "${GREEN}✓ All checks passed.${NC}"
  exit 0
fi
