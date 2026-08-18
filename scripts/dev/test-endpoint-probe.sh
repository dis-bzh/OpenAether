#!/usr/bin/env bash
# ==============================================================================
# Proves the claim the whole tunnel guard rests on: `nc -z` cannot tell a live
# Talos endpoint from a socket that merely accepts, and oa_talos_endpoint_ok can.
#
# WHY THIS EXISTS. `ssh -L` binds the local port itself and keeps listening long
# after the connection through it is dead. Every check in this repository that
# asked `nc -z` therefore answered "the tunnel is up" about a tunnel that was
# not. On 2026-08-18 that cost an upgrade fifteen minutes per node and needed a
# human reading the provider's API by hand to unstick it.
#
# Offline: two local listeners, no cloud, no cluster. Rung zero, so it can be
# re-run for ever instead of being believed once.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/lib/common.sh

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Well outside CP_BASE..WK_BASE+99, so close_tunnels never sweeps them, and
# derived from this process so two runs of the suite cannot collide on a listener
# the previous one has not released.
# ×5, not ×1: processes started together get CONSECUTIVE pids, so a spacing of
# one made run N's TLS port collide with run N+1's deaf port. Measured — five
# concurrent copies, two of them unable to bind.
BASE=$(( 40000 + ($$ % 4000) * 5 ))
DEAF=$((BASE))       # accepts TCP, speaks nothing — what a dead `ssh -L` looks like
TLS=$((BASE + 1))    # a real TLS server — what a live Talos apid looks like
SHUT=$((BASE + 2))   # nothing at all

CERT="$(mktemp -d)/s.pem"
cleanup() { kill "${DEAF_PID:-}" "${TLS_PID:-}" 2>/dev/null; rm -rf "$(dirname "$CERT")"; }
trap cleanup EXIT

command -v openssl >/dev/null || { echo "✗ openssl required"; exit 1; }
openssl req -x509 -newkey rsa:2048 -keyout "$CERT" -out "$CERT" -days 1 -nodes \
  -subj "/CN=probe-test" >/dev/null 2>&1 || { echo "✗ could not make a test cert"; exit 1; }

# A socket that accepts and then says nothing — exactly what a dead `ssh -L`
# leaves behind, and exactly what `nc -z` reports as healthy.
timeout 60 python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $DEAF)); s.listen(8)
while True:
    c, _ = s.accept()   # accept, then say nothing at all
" >/dev/null 2>&1 &
DEAF_PID=$!

timeout 60 openssl s_server -quiet -accept "$TLS" -cert "$CERT" -key "$CERT" \
  >/dev/null 2>&1 &
TLS_PID=$!

# Wait for both listeners with an INDEPENDENT check — a raw openssl handshake,
# not the function under test, so a genuinely broken probe still fails loudly
# instead of quietly timing out here. The TLS server needs longer than a TCP
# accept: waiting only for the connect made this file flaky under load, failing
# "the probe accepts a real TLS server" when the server simply was not up yet.
ready=0
for _ in $(seq 1 60); do
  if timeout 2 bash -c ">/dev/tcp/127.0.0.1/$DEAF" 2>/dev/null &&
     timeout 5 openssl s_client -connect "127.0.0.1:$TLS" -brief </dev/null 2>&1 |
       grep -qiE 'CONNECTION ESTABLISHED|Protocol version'; then
    ready=1; break
  fi
  sleep 0.5
done
[ "$ready" = 1 ] || { echo "✗ the test listeners never came up — this harness cannot conclude"; exit 1; }

echo "--- the socket that accepts but is not Talos (a dead ssh -L) ---"
if command -v nc >/dev/null 2>&1; then
  if nc -z -w2 127.0.0.1 "$DEAF" 2>/dev/null; then
    ok "nc -z calls it OPEN — this is the blindness the guard had to stop trusting"
  else
    bad "nc -z called it closed: this test no longer reproduces the defect it exists for"
  fi
else
  printf '  \033[33m~\033[0m nc absent — cannot demonstrate the blindness half\n'
fi
oa_talos_endpoint_ok 127.0.0.1 "$DEAF" && bad "the probe accepted a socket that speaks no TLS" \
  || ok "the probe refuses it"

echo "--- a real TLS endpoint (a live apid, or a node in maintenance mode) ---"
oa_talos_endpoint_ok 127.0.0.1 "$TLS" && ok "the probe accepts it" \
  || bad "the probe refused a real TLS server — it would call a healthy tunnel dead"

echo "--- nothing listening ---"
oa_talos_endpoint_ok 127.0.0.1 "$SHUT" && bad "the probe accepted a closed port" \
  || ok "the probe refuses it"

echo "--- the probe must not answer 'fine' when it cannot run ---"
SHIM="$(mktemp -d)"; for b in bash timeout grep; do ln -sf "$(command -v $b)" "$SHIM/$b"; done
rc=0; PATH="$SHIM" bash -c "source scripts/lib/common.sh; oa_talos_endpoint_ok 127.0.0.1 $TLS" >/dev/null 2>&1 || rc=$?
rm -rf "$SHIM"
[ "$rc" = 2 ] && ok "without openssl it exits 2 and says so, instead of guessing" \
  || bad "without openssl it exited ${rc} — a probe that cannot run must not answer"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
