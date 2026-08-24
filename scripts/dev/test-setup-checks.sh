#!/usr/bin/env bash
# setup.sh asks whether a tool is CURRENT, not merely present.
#
# The bare presence check installed the pin on a fresh machine and refused every
# upgrade afterwards, in silence, on every machine that had run the script once.
# Measured 2026-08-23 by the Cléa probe: a cold install reached helm 4.2.4 while
# upgrading over 4.2.3 left 4.2.3. The same shape had been found and fixed for
# feint two days earlier (scripts/dev/feint.sh:310), which is why it gets a
# harness rather than a comment.
#
# The function is extracted and driven against stub binaries: setup.sh runs its
# whole bootstrap when sourced, so there is nothing to import.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

sed -n '/^check_cmd() {/,/^}/p' "$ROOT/scripts/setup.sh" > "$TMP/fn.sh"
# ZERO FLOOR: an extractor that returns nothing makes every assertion below pass
# vacuously, which is the exact shape this file exists against.
grep -q 'command -v' "$TMP/fn.sh" || {
  echo "✗ could not extract check_cmd from setup.sh — the extractor is broken, not the script" >&2
  exit 1
}

stub() { # <name> <what `version` prints>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
mkdir -p "$TMP/bin"

run() { # <expected-rc> <label> <tool> [pin]
  local want="$1" label="$2"; shift 2
  local out rc
  out="$(PATH="$TMP/bin:$PATH" bash -c '
    RED=""; GREEN=""; NC=""
    . "$1"
    check_cmd "${2}" "${3:-}"' _ "$TMP/fn.sh" "$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else
    bad "$label (exit $rc, wanted $want) — $out"
  fi
  printf '%s' "$out" > "$TMP/last"
}

echo "=== present is not current ==="
stub helm "v4.2.3"
run 0 "no pin given: presence is still the only question" helm
run 0 "the pinned version installed" helm 4.2.3
run 1 "a different version is refused, not accepted as present" helm 4.2.4
grep -q '↻' "$TMP/last" && ok "and it says the version is not the pinned one" \
  || bad "the refusal does not name what it found"

echo
echo "=== the comparison is bounded on both sides ==="
stub helm "v4.2.30"
run 1 "4.2.30 does not satisfy a 4.2.3 pin" helm 4.2.3
stub helm "v14.2.3"
run 1 "14.2.3 does not satisfy a 4.2.3 pin" helm 4.2.3

echo
echo "=== the leading v is optional on either side ==="
stub tofu "OpenTofu v1.12.5"
run 0 "a tool that prints v against a pin that does not" tofu 1.12.5
stub flux "flux version 2.9.3"
run 0 "a tool that prints neither" flux 2.9.3

echo
echo "=== a missing tool is missing, whatever the pin says ==="
# A name nothing on this machine provides, rather than deleting the stub: the
# host has a real helm, so removing the stub falls through to it and the
# assertion passes for the wrong reason. A machine that works hides the defect.
run 1 "absent with a pin" clea-absent-by-construction 4.2.3
run 1 "absent without one" clea-absent-by-construction

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
