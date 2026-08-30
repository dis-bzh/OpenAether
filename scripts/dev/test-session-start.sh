#!/usr/bin/env bash
# The SessionStart hook must never cost a session its toolchain.
#
# `.claude/hooks/session-start.sh` runs under `set -euo pipefail` and is the only
# thing that installs tofu, talosctl, kubectl, task and the rest into a Claude
# Code on the web session. The Docker block appended to it can fail in three ways
# the ENVIRONMENT chooses and the repository cannot: no dockerd in the image, a
# daemon that never answers, a /var/log it may not write. Any of them returning
# non-zero aborts the hook, and the session comes out with no toolchain at all —
# a failure that looks nothing like its cause.
#
# So the assertions here are mostly about an exit code being zero. That reads
# thin and is not: `return 0` on every path is the whole guarantee.
#
# The function is extracted and driven against stubs — the hook runs its whole
# bootstrap when sourced, so there is nothing to import. Same shape as
# test-setup-checks.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/session-start.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

sed -n '/^start_dockerd() {/,/^}/p' "$HOOK" > "$TMP/fn.sh"
# ZERO FLOOR: an extractor that returns nothing makes every assertion below pass
# vacuously, which is the exact shape this file exists against.
grep -q 'command -v dockerd' "$TMP/fn.sh" || {
  echo "✗ could not extract start_dockerd from the hook — the extractor is broken, not the hook" >&2
  exit 1
}

mkdir -p "$TMP/bin"
LOG="$TMP/dockerd.log"
PIDFILE="$TMP/containerd.pid"

# `docker info` answers 0 once $TMP/ready exists, and every probe is counted:
# a loop that forgot its ceiling shows up as a number instead of as a hang.
cat > "$TMP/bin/docker" <<EOF
#!/bin/sh
echo p >> "$TMP/probes"
[ -f "$TMP/ready" ] && exit 0
exit 1
EOF

# The daemon comes up on a SLEEP, not on a wall clock: the stub below is
# instant, so anything timing-based here would be a race, and a racing test is
# worse than no test.
cat > "$TMP/bin/sleep" <<EOF
#!/bin/sh
n=\$(cat "$TMP/sleeps" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$TMP/sleeps"
if [ -f "$TMP/comes-up-after" ] && [ "\$n" -ge "\$(cat "$TMP/comes-up-after")" ]; then
  : > "$TMP/ready"
fi
exit 0
EOF

cat > "$TMP/bin/dockerd" <<EOF
#!/bin/sh
echo d >> "$TMP/launched"
exit 0
EOF

chmod +x "$TMP/bin/docker" "$TMP/bin/sleep" "$TMP/bin/dockerd"

reset() { rm -f "$TMP/ready" "$TMP/probes" "$TMP/sleeps" "$TMP/launched" \
                "$TMP/comes-up-after" "$TMP/bin/mkdir" "$LOG" "$PIDFILE"; }

OUT=""
RC=0
drive() { # [extra PATH entries in front]
  OUT="$(PATH="$TMP/bin:${1:-/bin:/usr/bin}" DOCKERD_LOG="$LOG" CONTAINERD_PIDFILE="$PIDFILE" \
    /bin/bash -c 'set -euo pipefail; SUDO_CMD=""; . "$1"; start_dockerd' _ "$TMP/fn.sh" 2>&1)"
  RC=$?
}

rc0() { # <label>
  if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 (exit $RC) — $OUT"; fi
}
says() { # <needle> <label>
  if grep -qF -- "$1" <<< "$OUT"; then ok "$2"; else bad "$2 — got: $OUT"; fi
}

# The launch is backgrounded, so the marker lands after the function returns.
# Bounded, and generous: a ceiling this far above the real cost fails only when
# nothing was launched at all.
launched() {
  local i
  for i in $(seq 1 100); do
    [ -f "$TMP/launched" ] && return 0
    sleep 0.02
  done
  return 1
}

echo "=== the daemon comes up ==="
reset
echo 2 > "$TMP/comes-up-after"
drive
rc0 "a stopped daemon is started"
says "Docker daemon started" "and it says so"
if launched; then ok "and dockerd was actually launched"; else bad "nothing was launched"; fi

echo
echo "=== an already-running daemon is left alone ==="
reset
: > "$TMP/ready"
drive
rc0 "a running daemon needs nothing"
says "already running" "and it says so"
# Not cosmetic: a second dockerd over a live socket is how you get two daemons
# fighting over /var/lib/docker.
sleep 0.2
if [ -f "$TMP/launched" ]; then bad "a second dockerd was launched over it"; else ok "and no second dockerd is launched over it"; fi

echo
echo "=== and when it cannot, the session still gets its toolchain ==="
# Only the stub directory on PATH, and bash reached by absolute path: leaving
# /usr/bin in front would find the REAL dockerd and judge an absent one present
# — green on this machine, meaningless everywhere.
reset
rm -f "$TMP/bin/dockerd"
drive "$TMP/bin"
rc0 "dockerd absent is survivable"
says "task local-*" "and it names the lanes that are unavailable"
cat > "$TMP/bin/dockerd" <<EOF
#!/bin/sh
echo d >> "$TMP/launched"
exit 0
EOF
chmod +x "$TMP/bin/dockerd"

reset
drive
rc0 "a daemon that never answers is survivable"
says "$LOG" "and it names the log to read"
reset
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/mkdir"
chmod +x "$TMP/bin/mkdir"
drive
rc0 "a log directory it cannot create is survivable"

echo
echo "=== a resumed container gets a second attempt ==="
# A container restored from a snapshot keeps a containerd pid from before it.
# dockerd sees the pid, refuses to start a managed containerd and gives up after
# 15 s; the pid is gone moments later. Measured 2026-08-27 — one attempt left
# the session with the warning and no daemon, a second came up in 2 s.
reset
drive
if [ "$(wc -l < "$TMP/launched")" -eq 2 ]; then
  ok "a first attempt that times out is followed by a second"
else
  bad "expected 2 launches, counted $(wc -l < "$TMP/launched")"
fi

# Clearing the pidfile is what makes the retry deterministic instead of hopeful.
reset
# Reaped HERE on purpose: a background child of a subshell is never reaped, and
# `kill -0` succeeds on the zombie it leaves — a dead pid that reads as alive.
sh -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
echo "$dead_pid" > "$PIDFILE"
drive
if [ -f "$PIDFILE" ]; then bad "a containerd pidfile whose process is gone was kept"; else ok "a containerd pidfile whose process is gone is cleared"; fi

# The dangerous half, and the reason this is not a pkill: a live containerd
# belongs to a working daemon somewhere, and taking it down to fix one that is
# not running trades a real outage for a hypothetical one.
reset
echo $$ > "$PIDFILE"
drive
if [ -f "$PIDFILE" ]; then ok "a LIVE containerd is left alone"; else bad "a live containerd's pidfile was deleted"; fi


echo
echo "=== the wait is bounded ==="
# 1 probe before the first launch, then 20 per attempt, twice. A ceiling that
# drifts silently is a hook that hangs a session for minutes with no output.
reset
drive
probes="$(wc -l < "$TMP/probes")"
if [ "$probes" -eq 41 ]; then
  ok "it gives up rather than looping (1 + 2 × 20 probes)"
else
  bad "expected 1 + 2 × 20 probes, counted $probes"
fi
says "after two tries" "and says it tried twice"

echo
echo "$PASS passed, $FAIL failed"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
