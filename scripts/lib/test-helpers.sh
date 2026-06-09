#!/usr/bin/env bash
# OpenAether 0.5.0 — lib de helpers pour les tests sprint 0
# À sourcer dans les scripts de test: source $(dirname $0)/lib/test-helpers.sh

# Couleurs
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export NC='\033[0m' # No Color

# Compteurs
export TESTS_PASSED=0
export TESTS_FAILED=0
export TESTS_TOTAL=0

log_ok() {
    echo -e "${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED+1))
    TESTS_TOTAL=$((TESTS_TOTAL+1))
}

log_ko() {
    echo -e "${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo -e "  ${RED}→${NC} $2"
    TESTS_FAILED=$((TESTS_FAILED+1))
    TESTS_TOTAL=$((TESTS_TOTAL+1))
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
    echo -e "  $1"
}

log_section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

assert_equal() {
    local actual="$1"
    local expected="$2"
    local message="${3:-assertion}"
    if [ "$actual" = "$expected" ]; then
        log_ok "$message (got '$actual')"
    else
        log_ko "$message" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assertion}"
    if echo "$haystack" | grep -q "$needle"; then
        log_ok "$message (found '$needle')"
    else
        log_ko "$message" "'$needle' not found in '$haystack'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assertion}"
    if echo "$haystack" | grep -q "$needle"; then
        log_ko "$message" "'$needle' found but should not be in '$haystack'"
    else
        log_ok "$message ('$needle' not found as expected)"
    fi
}

wait_for_pod() {
    local label="$1"
    local namespace="$2"
    local timeout="${3:-120}"
    echo -n "  waiting for pod with label $label in ns $namespace (timeout ${timeout}s)..."
    if kubectl wait --for=condition=ready \
        -l "$label" \
        -n "$namespace" \
        "pod" \
        --timeout="${timeout}s" >/dev/null 2>&1; then
        echo " ready"
        return 0
    else
        echo " TIMEOUT"
        return 1
    fi
}

wait_for_secret() {
    local name="$1"
    local namespace="$2"
    local timeout="${3:-30}"
    echo -n "  waiting for secret $name in ns $namespace..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl get secret "$name" -n "$namespace" >/dev/null 2>&1; then
            echo " found"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed+2))
    done
    echo " TIMEOUT"
    return 1
}

print_summary() {
    local script_name="${1:-test}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $script_name: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        return 1
    fi
    return 0
}
