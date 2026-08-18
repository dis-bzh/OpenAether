#!/usr/bin/env bash
# ==============================================================================
# explain-failure.sh exists because nothing told the operator a resource was
# TAINTED, and re-running destroyed a load balancer the provider was still
# building. These assertions keep that message alive.
#
# Offline: a stub `tofu` on PATH serves a crafted state. No cloud, no backend.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
stub() { printf '#!/usr/bin/env bash\n[ "$1" = state ] && cat %q\nexit 0\n' "$SB/state.json" >"$SB/tofu"; chmod +x "$SB/tofu"; }
run()  { PATH="$SB:$PATH" ./scripts/internal/explain-failure.sh "$SB" 2>&1; }

echo "--- a tainted resource must be named, with its untaint command ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[
 {"module":"module.ovh[0]","type":"openstack_lb_loadbalancer_v2","name":"k8s",
  "instances":[{"index_key":0,"status":"tainted","attributes":{}}]},
 {"module":"module.ovh[0]","type":"openstack_compute_instance_v2","name":"worker",
  "instances":[{"index_key":1,"attributes":{}}]}
]}
JSON
stub; OUT="$(run)"
grep -q 'module.ovh\[0\].openstack_lb_loadbalancer_v2.k8s\[0\]' <<<"$OUT" \
  && ok "the tainted address is printed in full" || bad "the tainted address is missing from the output"
grep -q "tofu untaint 'module.ovh\[0\].openstack_lb_loadbalancer_v2.k8s\[0\]'" <<<"$OUT" \
  && ok "and the exact untaint command with it" || bad "no untaint command was offered"
grep -qi 'DESTROYED AND REBUILT' <<<"$OUT" \
  && ok "it says what re-running would actually do" || bad "it does not explain the cost of re-running"
grep -q 'openstack_compute_instance_v2' <<<"$OUT" \
  && bad "it named a healthy resource — the signal is diluted" \
  || ok "healthy resources are not mentioned"

echo "--- silent when nothing is tainted (it runs on every failed apply) ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[{"module":"module.ovh[0]","type":"openstack_compute_instance_v2","name":"worker",
 "instances":[{"index_key":0,"attributes":{}}]}]}
JSON
stub; OUT="$(run)"
[ -z "$OUT" ] && ok "prints nothing at all" || bad "printed on a clean state: '${OUT:0:60}'"

echo "--- never breaks the caller, whatever it meets ---"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SB/tofu"; chmod +x "$SB/tofu"
run >/dev/null 2>&1; [ $? -eq 0 ] && ok "a tofu that fails still exits 0" || bad "it propagated a failure"
printf '#!/usr/bin/env bash\necho "not json"\n' >"$SB/tofu"; chmod +x "$SB/tofu"
run >/dev/null 2>&1; [ $? -eq 0 ] && ok "unparseable state still exits 0" || bad "it propagated a failure"
PATH="$SB:$PATH" ./scripts/internal/explain-failure.sh /nonexistent-dir >/dev/null 2>&1
[ $? -eq 0 ] && ok "a missing directory still exits 0" || bad "it propagated a failure"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
