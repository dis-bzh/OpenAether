#!/usr/bin/env bash
# ==============================================================================
# Say what a FAILED apply left behind, and what re-running would cost.
#
# WHY. On 2026-08-18 an OVH load balancer timed out at 9m51s while the provider
# was still building it. OpenTofu marks such a resource TAINTED, so the obvious
# reaction — re-run — DESTROYS the thing that was nearly ready and starts the
# wait again. An hour went into that loop, and nothing on screen mentioned the
# word "tainted". This is that hour, spent once.
#
# Run from a Taskfile `defer:` guarded on {{.EXIT_CODE}}, so it costs nothing
# when the apply succeeded. Never fails the caller: it is a diagnosis, and a
# diagnosis that breaks the build is worse than no diagnosis.
#
# Usage: explain-failure.sh <tofu_dir>
# ==============================================================================
set -uo pipefail
cd "${1:-.}" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

STATE="$(timeout 90 tofu state pull 2>/dev/null)" || exit 0
[ -n "$STATE" ] || exit 0

TAINTED="$(jq -r '
  .resources[]? as $r | $r.instances[]? |
  select(.status == "tainted") |
  ($r.module // "") as $m |
  (if $m == "" then "" else $m + "." end) + $r.type + "." + $r.name +
  (if .index_key == null then "" else "[" + (.index_key|tostring) + "]" end)
' <<<"$STATE" 2>/dev/null)"

[ -n "$TAINTED" ] || exit 0

printf '\n\033[33m─── what the failure left behind ───\033[0m\n' >&2
printf 'OpenTofu marked %s resource(s) TAINTED:\n\n' "$(wc -l <<<"$TAINTED")" >&2
sed 's/^/    /' <<<"$TAINTED" >&2
cat >&2 <<'TXT'

  A tainted resource is DESTROYED AND REBUILT on the next apply. If it timed out
  while the provider was still creating it — the usual case for a load balancer —
  re-running throws away the one that was nearly ready and pays the wait again.

  Ask the provider what state it is really in FIRST. If the provider says the
  resource is fine, keep it instead of rebuilding:

TXT
while IFS= read -r addr; do
  [ -n "$addr" ] && printf "    tofu untaint '%s'\n" "$addr" >&2
done <<<"$TAINTED"
printf '\n  Then re-run. If the provider says it is genuinely stuck, leave it tainted.\n' >&2
printf '  A managed load balancer stuck mid-creation cannot be deleted by anyone but\n' >&2
printf '  the provider, and it pins the network behind it — see .claude/skills/teardown.\n\n' >&2
exit 0
