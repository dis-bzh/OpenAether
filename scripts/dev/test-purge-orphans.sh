#!/usr/bin/env bash
# Unit tests for the LAST sentence between a failed teardown and a bill.
#
# `purge-orphans/<provider>.py` is what staging.yml calls "Confirm the provider
# is clean", what docs/first-cluster.md ends on, and what an operator reads to
# decide a session cost nothing more. It answers a question — "is anything still
# there?" — and the dangerous answer is not "yes". It is "no" said by a script
# that was never allowed to look.
#
# Measured 2026-08-17, before the fix, with every call forced to HTTP 403 and no
# credentials at all: scaleway.py printed thirteen "⚠ unreachable" lines and then
# "Nothing to purge — the project is clean." with exit 0; outscale.py printed
# NOTHING and did the same. A total authentication failure was indistinguishable
# from a clean account, in the output and in the exit code.
#
# No network: urllib is monkey-patched in-process to raise HTTPError 403.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Runs a purge script with every HTTP call answered 403, printing "<rc>\n<output>".
run_403() { # <script> [extra env assignments...]
  local script="$1"; shift
  env "$@" python3 - "$ROOT/scripts/ops/purge-orphans/$script" <<'PY' 2>&1
import runpy, sys, urllib.request, urllib.error, io

def refuse(*a, **k):
    raise urllib.error.HTTPError('https://stub.invalid/x', 403, 'Forbidden', {},
                                 io.BytesIO(b'{"message":"denied"}'))

urllib.request.urlopen = refuse
sys.argv = [sys.argv[1]]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

echo "=== purge-orphans: a refused API is not a clean account ==="

# Credentials must be PRESENT but useless: the scripts read them at import time
# and a KeyError would abort before reaching the logic under test — which would
# pass this file for the wrong reason.
SCW_ENV=(SCW_SECRET_KEY=stub SCW_DEFAULT_PROJECT_ID=stub SCW_DEFAULT_REGION=fr-par)
OSC_ENV=(OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2)

for case in "scaleway.py:${SCW_ENV[*]}" "outscale.py:${OSC_ENV[*]}"; do
  script="${case%%:*}"; envs="${case#*:}"
  # shellcheck disable=SC2086  # envs is a deliberate list of assignments
  out="$(run_403 "$script" $envs)"; rc=$?

  if [ "$rc" -ne 0 ]; then
    ok "${script}: a fully refused API exits non-zero (rc=${rc})"
  else
    bad "${script}: every call was refused and it exited 0 — a bill looks like an all-clear"
  fi

  if grep -qiE 'clean' <<<"$out"; then
    bad "${script}: it said the account is clean after answering nothing"
  else
    ok "${script}: it does not claim the account is clean"
  fi

  # Silence is the Outscale-specific half of the defect: it swallowed the error
  # into an empty listing and printed one line for the whole run.
  if grep -qiE 'unreachable|refused' <<<"$out"; then
    ok "${script}: it names the refusal in its output"
  else
    bad "${script}: it refused silently — a transcript reader cannot tell"
  fi
done

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
