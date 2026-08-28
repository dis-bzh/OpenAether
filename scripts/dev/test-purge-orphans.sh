#!/usr/bin/env bash
# Unit tests for the LAST sentence between a failed teardown and a bill.
#
# `purge-orphans/<provider>.py` is what docs/first-cluster.md ends on, and what
# an operator reads to
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


# --- the OTHER half: the listings ANSWER, the deletions all fail --------------
# Measured live on Outscale 2026-08-20, on a Net only the provider can clear:
# six resources found, six deletions refused, and the run still ended "Outscale
# purge complete" with exit 0. The refusals WERE printed; nothing counted them,
# so every caller reading the exit code heard "the account is clean".
echo
echo "=== --apply: everything found, every deletion refused ==="

run_apply_refused() { # <script>
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OUTSCALE_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/$1" <<'PYSTUB' 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

# Read* answers with one resource; anything that MUTATES is refused 409 — the
# shape Outscale really returned (ResourceConflict on a Net still in use).
CANNED = {
    'ReadNets':             {'Nets': [{'NetId': 'vpc-stub', 'IpRange': '10.0.0.0/16'}]},
    'ReadSubnets':          {'Subnets': [{'SubnetId': 'subnet-stub'}]},
    'ReadInternetServices': {'InternetServices': [{'InternetServiceId': 'igw-stub', 'NetId': 'vpc-stub'}]},
}

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    if action.startswith('Read'):
        return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())
    raise urllib.error.HTTPError(req.full_url, 409, 'Conflict', {},
                                 io.BytesIO(b'{"Errors":[{"Code":"9092"}]}'))

urllib.request.urlopen = fake
sys.argv = [sys.argv[1], '--apply']
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PYSTUB
}

out="$(run_apply_refused outscale.py)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "outscale.py --apply: every deletion refused and it still exited 0 — a caller reads that as clean"
else
  ok "outscale.py --apply: deletions refused, exit ${rc} — not an all-clear"
fi
if grep -qiE 'NOT clean|deletion' <<<"$out"; then
  ok "outscale.py --apply: it says in words that the deletions failed"
else
  bad "outscale.py --apply: the transcript never says the deletions failed"
fi
if grep -qiE 'resource\(s\) deleted\. The account is clean' <<<"$out"; then
  bad "outscale.py --apply: it claimed resources were deleted when none were"
else
  ok "outscale.py --apply: it does not claim a deletion that did not happen"
fi

# --- ovh.py: auth succeeds, servers are found, one other endpoint is refused --
# ovh.py's get() raises rather than swallowing, so a TOTAL auth failure already
# crashes non-zero — not this gap (verified below, unchanged). The gap is a
# PARTIAL refusal: auth works, servers list fine, then floating-ips answers
# 403. Before the fix that exception propagated out of get() uncaught: the run
# died mid-listing with a traceback, never reaching routers/networks/security
# groups or its own summary — which is not "clean", but the run's own findings
# vanished with it. It must count the refusal and keep going, like its
# siblings, and still report what it DID find.
echo
echo "=== ovh.py: auth OK, servers found, floating-ips refused 403 ==="

run_403_ovh_partial() {
  env OS_AUTH_URL=https://stub.invalid/v3 OS_USERNAME=stub OS_PASSWORD=stub \
      OS_PROJECT_ID=stub OS_REGION_NAME=stub \
      python3 - "$ROOT/scripts/ops/purge-orphans/ovh.py" <<'PY' 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

class FakeResp(io.BytesIO):
    def __init__(self, data, headers=None):
        super().__init__(data)
        self.headers = headers or {}
    def __enter__(self): return self
    def __exit__(self, *a): return False

CATALOG = {"token": {"catalog": [
    {"type": "network", "endpoints": [{"interface": "public", "region": "stub", "url": "https://stub.invalid/network"}]},
    {"type": "compute", "endpoints": [{"interface": "public", "region": "stub", "url": "https://stub.invalid/compute"}]},
]}}

def fake(req, *a, **k):
    u = req.full_url
    if u.endswith('/auth/tokens'):
        return FakeResp(json.dumps(CATALOG).encode(), headers={'X-Subject-Token': 'stub'})
    if u.endswith('/servers'):
        return FakeResp(json.dumps({'servers': [{'id': 'srv-stub', 'name': 'stub-server'}]}).encode())
    raise urllib.error.HTTPError(u, 403, 'Forbidden', {}, io.BytesIO(b'{}'))

urllib.request.urlopen = fake
sys.argv = [sys.argv[1]]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

out="$(run_403_ovh_partial)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "ovh.py: found resources + a refused endpoint still exits non-zero (rc=${rc})"
else
  bad "ovh.py: exited 0 with a refused endpoint in the middle of the run"
fi
if grep -qi 'traceback' <<<"$out"; then
  bad "ovh.py: a refused endpoint crashed the run instead of being counted — later listings never ran"
else
  ok "ovh.py: a refused endpoint does not crash the run"
fi
if grep -qiE 'unreachable' <<<"$out"; then
  ok "ovh.py: it names the refusal in its output"
else
  bad "ovh.py: it refused silently — a transcript reader cannot tell"
fi
if grep -qiE 'resource\(s\) targeted' <<<"$out"; then
  ok "ovh.py: it still reaches its own summary after the refusal"
else
  bad "ovh.py: it never reached its own summary — the refusal ended the run early"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
