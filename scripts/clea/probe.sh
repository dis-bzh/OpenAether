#!/usr/bin/env bash
# Prove a bump before anyone merges it: install it from cold, then upgrade over
# the version that was there.
#
# The second half is the one that finds things. `scripts/dev/feint.sh:310`
# records what it would have caught: the pin moved to 0.10.0 and every machine
# that had already run the lane kept 0.9.0, because the installer checked that
# the binary existed and never asked which version it was.
#
# Bare ubuntu:24.04, not the runner image: a machine that already has the tool
# hides the defect. Only curl and ca-certificates are added — anything else the
# installer needs and does not install is a finding, not a prerequisite to
# paper over.
#
# Usage: probe.sh <dep> <version> <installer> <version-cmd> [stdin-for-installer]
#   CLEA_IMAGE  base image           (default: ubuntu:24.04)
#   CLEA_ROOT   repository to mount  (default: git toplevel)
set -uo pipefail

DEP="${1:?dep}"; VERSION="${2:?version}"; INSTALLER="${3:?installer}"
VERSION_CMD="${4:?version command}"; STDIN="${5:-}"
IMAGE="${CLEA_IMAGE:-ubuntu:24.04}"
ROOT="${CLEA_ROOT:-$(git rev-parse --show-toplevel)}"
CLEA="$ROOT/scripts/clea/clea.py"
NAME="clea-probe-$(printf '%s' "$DEP" | tr -c 'a-zA-Z0-9' '-')-$$"

# This script bumps a pin and restores the tree with `git checkout -- .`, which
# would take uncommitted work with it. Refuse rather than find out.
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  echo "✗ ${ROOT} has uncommitted changes; this script restores the tree by discarding them" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  git -C "$ROOT" checkout -- . 2>/dev/null || true
}
trap cleanup EXIT

# Bounded on both sides, so 3.52.0 does not match 3.52.01 and 1.13.9 does not
# match 1.13.90. The leading v is optional because half the tools print it.
version_re() { printf '(^|[^0-9.])v?%s([^0-9.]|$)' "$(printf '%s' "${1#v}" | sed 's/\./\\./g')"; }

in_box() {
  if [ -n "$STDIN" ]; then
    printf '%b' "$STDIN" | docker exec -i -w /repo "$NAME" bash -lc "$1"
  else
    docker exec -w /repo "$NAME" bash -lc "$1"
  fi
}

echo "=== ${DEP} -> ${VERSION} ==="

docker run -d --name "$NAME" -v "$ROOT:/repo" -w /repo "$IMAGE" sleep 3600 >/dev/null || {
  echo "✗ could not start ${IMAGE}" >&2; exit 1; }
in_box 'apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null' \
  || { echo "✗ could not add curl to the container" >&2; exit 1; }

# --- 1. upgrade: the OLD pin first, so there is something to upgrade over -----
OLD_OUT="$(in_box "$INSTALLER >/dev/null 2>&1; $VERSION_CMD" 2>&1)"
OLD_VERSION="$(printf '%s' "$OLD_OUT" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
if [ -n "$OLD_VERSION" ]; then
  ok "installed at the current pin first: ${OLD_VERSION}"
else
  bad "the installer at the current pin reported no version — cannot upgrade over nothing"
  printf '%s\n' "$OLD_OUT" | tail -20
fi

# --- 2. the bump itself, on the host: the container has no Python -------------
if ! python3 "$CLEA" --root "$ROOT" bump "$DEP" "$VERSION"; then
  bad "clea bump refused — nothing was rewritten, so a probe here would test the tree it started with"
  echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi

# --- 3. upgrade in place -----------------------------------------------------
UP_OUT="$(in_box "$INSTALLER 2>&1; echo ---; $VERSION_CMD" 2>&1)"
if printf '%s' "$UP_OUT" | grep -qE "$(version_re "$VERSION")"; then
  ok "upgrade over ${OLD_VERSION:-an existing install} reached ${VERSION}"
else
  bad "upgrade did not reach ${VERSION} — the installer left ${OLD_VERSION:-what was there}"
  printf '%s\n' "$UP_OUT" | tail -25
fi

# --- 4. install from cold, in a container that never had it ------------------
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -v "$ROOT:/repo" -w /repo "$IMAGE" sleep 3600 >/dev/null
in_box 'apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null'
COLD_OUT="$(in_box "$INSTALLER 2>&1; echo ---; $VERSION_CMD" 2>&1)"
if printf '%s' "$COLD_OUT" | grep -qE "$(version_re "$VERSION")"; then
  ok "cold install on a machine that never had it reached ${VERSION}"
else
  bad "cold install did not reach ${VERSION}"
  printf '%s\n' "$COLD_OUT" | tail -25
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
