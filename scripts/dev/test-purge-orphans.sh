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

# --- outscale.py: leftover snapshots are visible, and "clean" stops lying ----
# The core of #71: a duplicate snapshot from a failed image build sat in the
# account while outscale.py never even asked ReadSnapshots, so "account is
# clean" was true of everything it looked at and false of the account. Images
# are deliberately out of scope here — see the comment in outscale.py for why.
#
# Five scenarios: #1 is the regression guard (must not cry wolf on the
# ordinary empty case), #2 is #71 itself, #3 is its twin in the --apply
# success path, #4 reproduces the bug review actually caught — a REFUSED
# ReadSnapshots after some other resource was purged clean — and #5 checks
# that a failed deletion still wins the exit code over a leftover snapshot.
echo
echo "=== outscale.py: snapshot artifacts are seen, not silently skipped ==="

run_osc_canned() { # <CANNED python-dict-literal as a string> [extra argv...]
  local canned="$1"; shift
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/outscale.py" "$@" <<PY 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

CANNED = $canned

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

# Same as run_osc_canned, but any action named in FAIL_ACTIONS raises HTTP 403
# instead of answering — needed to reproduce a REFUSED call (not just an empty
# one) alongside other calls that succeed normally.
run_osc_canned_fail() { # <CANNED python-dict-literal> <FAIL_ACTIONS python-list-literal> [extra argv...]
  local canned="$1"; local fail_actions="$2"; shift 2
  env OUTSCALE_ACCESS_KEY_ID=stub OUTSCALE_SECRET_KEY=stub OSC_REGION=eu-west-2 \
      python3 - "$ROOT/scripts/ops/purge-orphans/outscale.py" "$@" <<PY 2>&1
import runpy, sys, json, io, urllib.request, urllib.error

CANNED = $canned
FAIL_ACTIONS = $fail_actions

def fake(req, *a, **k):
    action = req.full_url.rsplit('/', 1)[-1]
    if action in FAIL_ACTIONS:
        raise urllib.error.HTTPError(req.full_url, 403, 'Forbidden', {},
                                     io.BytesIO(b'{"message":"denied"}'))
    return io.BytesIO(json.dumps(CANNED.get(action, {})).encode())

urllib.request.urlopen = fake
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name='__main__')
except SystemExit as e:
    sys.exit(e.code if isinstance(e.code, int) else 1)
PY
}

# 1. Genuinely empty account — every Read* (including the two new ones)
#    returns nothing. Must still say "clean": the case this fix must not break.
out="$(run_osc_canned '{}')"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "outscale.py: a genuinely empty account (incl. no snapshots/images) still exits 0"
else
  bad "outscale.py: a genuinely empty account no longer exits 0 (rc=${rc}) — false positive"
fi
if grep -qiE 'account is clean' <<<"$out"; then
  ok "outscale.py: it still says clean when nothing at all is present"
else
  bad "outscale.py: it stopped saying clean on a genuinely empty account"
fi

# 2. Only a leftover snapshot — every Net-dependency listing is empty
#    (TOTAL stays 0), but ReadSnapshots answers one. This is #71 itself.
ONLY_SNAPSHOT='{"ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-orphan", "State": "completed", "VolumeSize": 10}]}}'
out="$(run_osc_canned "$ONLY_SNAPSHOT")"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py: an orphan snapshot with nothing else present exits non-zero (rc=${rc})"
else
  bad "outscale.py: an orphan snapshot present and it still exited 0 — the #71 bug"
fi
if grep -qiE 'account is clean' <<<"$out"; then
  bad "outscale.py: it said the account is clean while an orphan snapshot sat there"
else
  ok "outscale.py: it does not claim clean while the snapshot is present"
fi
if grep -q 'snap-orphan' <<<"$out"; then
  ok "outscale.py: it names the orphan snapshot in its output"
else
  bad "outscale.py: the snapshot was found but never named — a transcript reader can't act on it"
fi

# 3. Net resources purged successfully AND a snapshot is left over — the
#    "N resource(s) deleted. The account is clean." branch must not lie either.
DELETED_PLUS_SNAPSHOT='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}, "ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-leftover", "State": "completed", "VolumeSize": 5}]}}'
out="$(run_osc_canned "$DELETED_PLUS_SNAPSHOT" --apply)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py --apply: resources deleted but a snapshot remains still exits non-zero (rc=${rc})"
else
  bad "outscale.py --apply: a snapshot remained after a successful purge and it exited 0"
fi
if grep -qiE 'account is clean' <<<"$out" && ! grep -qiE 'NOT fully clean' <<<"$out"; then
  bad "outscale.py --apply: claimed clean while snap-leftover was still listed"
else
  ok "outscale.py --apply: does not claim a plain clean while the snapshot remains"
fi
if grep -q 'snap-leftover' <<<"$out"; then
  ok "outscale.py --apply: names the leftover snapshot after a successful net purge"
else
  bad "outscale.py --apply: the leftover snapshot was never named post-purge"
fi

# 4. The bug review actually caught: a Net is purged successfully (TOTAL>0,
#    FAILED==0) AND ReadSnapshots itself is REFUSED (not merely empty) — a
#    first fix attempt fell through this exact combination to the plain
#    "account is clean" message, because the unreachable-artifacts check only
#    guarded the TOTAL==0 branch.
ONE_NET='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}}'
out="$(run_osc_canned_fail "$ONE_NET" "['ReadSnapshots']" --apply)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "outscale.py --apply: net purged + ReadSnapshots refused still exits non-zero (rc=${rc})"
else
  bad "outscale.py --apply: net purged + ReadSnapshots refused exited 0 — the exact bug review caught"
fi
if grep -qiE '^[0-9]+ resource\(s\) deleted\. The account is clean\.$' <<<"$out"; then
  bad "outscale.py --apply: claimed a plain clean while snapshot visibility was refused"
else
  ok "outscale.py --apply: does not claim a plain clean when snapshot visibility was refused"
fi
if grep -qiE 'visibility was refused|refused, unconfirmed' <<<"$out"; then
  ok "outscale.py --apply: says snapshot visibility was refused, not silently clean"
else
  bad "outscale.py --apply: a refused ReadSnapshots after a successful purge left no trace in the output"
fi

# 5. A deletion FAILS in the same run a snapshot is ALSO present — the failed
#    deletion (exit 3) must win over the milder "leftover snapshot" wording
#    (exit 1): FAILED is checked first in outscale.py on purpose.
NET_PLUS_SNAPSHOT='{"ReadNets": {"Nets": [{"NetId": "vpc-stub", "IpRange": "10.0.0.0/16"}]}, "ReadSnapshots": {"Snapshots": [{"SnapshotId": "snap-alongside", "State": "completed", "VolumeSize": 5}]}}'
out="$(run_osc_canned_fail "$NET_PLUS_SNAPSHOT" "['DeleteNet']" --apply)"; rc=$?
if [ "$rc" -eq 3 ]; then
  ok "outscale.py --apply: a failed deletion alongside a leftover snapshot exits 3, not 1"
else
  bad "outscale.py --apply: expected exit 3 (failed deletion wins), got rc=${rc}"
fi
if grep -qiE 'deletion\(s\) failed' <<<"$out"; then
  ok "outscale.py --apply: reports the failed deletion, not just the leftover snapshot"
else
  bad "outscale.py --apply: the failed-deletion message is missing when a snapshot is also present"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
