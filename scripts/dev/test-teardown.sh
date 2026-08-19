#!/usr/bin/env bash
# Unit tests for the teardown gates of fleet-down.sh / edge-down.sh, against a
# STUB kubectl.
#
# Teardown is where a wrong answer costs an invoice: every branch below decides
# either "destroy the management" or "report this cluster as gone". Read an API
# error as an empty list and the management dies while its children keep
# billing; read it as an absence and a cluster is reported deleted while its VMs
# run. Both happened. Neither needed a cloud to catch — they needed a fake
# kubectl and thirty seconds.
#
# Same harness as test-rolling-replace.sh: a stub answering from a plan file
# keyed on argv, able to FAIL a given query, which is the case these scripts
# kept getting wrong. Here we run the scripts whole rather than sourcing
# functions, because what is under test is the control flow between the gates —
# in particular what does NOT run after one of them trips.
#
# Usage: test-teardown.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLEET_DOWN="$ROOT/scripts/ops/fleet-down.sh"
EDGE_DOWN="$ROOT/scripts/ops/edge-down.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# Captured before the stub dir goes on PATH: the sleep stub below still has to
# yield, or the wait loops spin thousands of iterations per second.
REAL_SLEEP="$(command -v sleep)"

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# --- the stubs ----------------------------------------------------------------
# STUB_PLAN is a file of "match<TAB>rc<TAB>stdout" lines. The first line whose
# match is a substring of the joined argv wins, so a narrower match goes first.
# No line matching = rc 1, empty. One record per line, so multi-line output is
# written with %% where a newline goes.
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
argv="$*"
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$argv" >>"$STUB_LOG"
[ -n "${STUB_PLAN:-}" ] && [ -f "$STUB_PLAN" ] || { exit 1; }
while IFS=$'\t' read -r match rc out; do
  [ -n "$match" ] || continue
  case "$argv" in
    *"$match"*)
      # Like the real thing: results on stdout, diagnostics on stderr. Several
      # of the gates below read one and not the other, which is the whole point.
      out="${out//%%/$'\n'}"
      if [ "${rc:-0}" = 0 ]; then
        [ -n "$out" ] && printf '%s\n' "$out"
      else
        [ -n "$out" ] && printf '%s\n' "$out" >&2
      fi
      exit "${rc:-0}"
      ;;
  esac
done <"$STUB_PLAN"
exit 1
STUB

# Tripwires. `task destroy` is the irreversible step of fleet-down and
# verify-provider-clean.py is what turns "objects gone" into "fully deleted";
# both record that they ran, so a test can assert they did NOT.
cat >"$STUB_DIR/task" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_TASK_LOG:?}"
# STUB_TASK_FAIL_TIMES: fail the first N invocations, then honour STUB_TASK_RC.
# The count lives in a file because every call is a fresh process, and a stub
# that cannot change its mind cannot exercise a retry loop at all.
# STUB_TASK_MSG: what the "provider" says while refusing. fleet-down classifies
# its own failure from this text, so a stub that says nothing cannot exercise it.
[ -n "${STUB_TASK_MSG:-}" ] && printf '%s\n' "$STUB_TASK_MSG" >&2
if [ -n "${STUB_TASK_FAIL_TIMES:-}" ] && [ -n "${STUB_TASK_COUNT_FILE:-}" ]; then
  n=$(cat "$STUB_TASK_COUNT_FILE" 2>/dev/null || echo 0)
  n=$((n + 1)); printf '%s' "$n" >"$STUB_TASK_COUNT_FILE"
  [ "$n" -le "$STUB_TASK_FAIL_TIMES" ] && exit 1
fi
exit "${STUB_TASK_RC:-0}"
STUB

# Nothing here may reach OpenTofu. If it does, the test that let it must fail.
cat >"$STUB_DIR/tofu" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_TOFU_LOG:?}"
exit 0
STUB

cat >"$STUB_DIR/python3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_PY_LOG:?}"
printf '%s\n' "${STUB_PY_OUT:-stub verify output}"
exit "${STUB_PY_RC:-0}"
STUB

cat >"$STUB_DIR/sleep" <<STUB
#!/usr/bin/env bash
exec "$REAL_SLEEP" 0.02
STUB

chmod +x "$STUB_DIR"/kubectl "$STUB_DIR"/task "$STUB_DIR"/tofu \
         "$STUB_DIR"/python3 "$STUB_DIR"/sleep
export PATH="$STUB_DIR:$PATH"

export STUB_PLAN="$STUB_DIR/plan"
export STUB_LOG="$STUB_DIR/kubectl.log"
export STUB_TASK_LOG="$STUB_DIR/task.log"
export STUB_TOFU_LOG="$STUB_DIR/tofu.log"
export STUB_PY_LOG="$STUB_DIR/python3.log"

# fleet-down refuses to start without a readable kubeconfig, and rightly so.
# Its content is never parsed here: the stub kubectl answers, not a server.
printf 'stub kubeconfig, never parsed\n' >"$STUB_DIR/kubeconfig"
export KUBECONFIG="$STUB_DIR/kubeconfig"

# An UNQUALIFIED Cluster verb: `cluster` resolves to whichever CRD is installed,
# and with the CAPI ones gone that is CNPG's. Deleting a database instead of an
# edge is not a recoverable typo, so no run below may issue one.
UNQUALIFIED='^(get|delete|patch) clusters?( |$)'

CLUSTER_INFO_OK='cluster-info\t0\tKubernetes control plane is running\n'

plan() { printf '%b' "$1" >"$STUB_PLAN"; }

run() { # <script> <args...> — captures combined output in OUT, status in RC
  : >"$STUB_LOG"; : >"$STUB_TASK_LOG"; : >"$STUB_TOFU_LOG"; : >"$STUB_PY_LOG"
  if OUT="$("$@" </dev/null 2>&1)"; then RC=0; else RC=$?; fi
}

# One-line output, so a failure says what it saw instead of only which line.
flat() { printf '%s' "${OUT//$'\n'/ | }"; }

expect_rc()  { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (exit $RC: $(flat))"; fi; }
expect_out() { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 (no '$1' in: $(flat))" ;; esac; }
refute_out() { case "$OUT" in *"$1"*) bad "$2 (found '$1' in: $(flat))" ;; *) ok "$2" ;; esac; }

expect_destroyed() { # the management destroy ran
  if [ -s "$STUB_TASK_LOG" ]; then ok "$1"; else bad "$1 (task destroy never ran)"; fi
}
refute_destroyed() { # …and, far more important, that it did not
  if [ -s "$STUB_TASK_LOG" ]
    then bad "$1 — task RAN: $(tr '\n' ';' <"$STUB_TASK_LOG")"
    else ok "$1"
  fi
}
expect_log() { # <ere> <label> — over the kubectl argv log
  if grep -Eq "$1" "$STUB_LOG"; then ok "$2"; else bad "$2 (no /$1/ in: $(tr '\n' ';' <"$STUB_LOG"))"; fi
}
refute_log() {
  if grep -Eq "$1" "$STUB_LOG"
    then bad "$2 — matched: $(grep -Em1 "$1" "$STUB_LOG")"
    else ok "$2"
  fi
}

echo "=== fleet-down: an unanswered child-cluster query is not an absence ==="

# THE billing defect, and it is UNREACHABILITY that causes it. A query we could
# not answer looks identical to a childless management, and the very next step
# destroys the management — the only thing that could ever delete the children.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t1\tUnable to connect to the server: dial tcp 10.0.0.1:6443: connect: connection refused\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 1 "an unanswerable query aborts fleet-down"
refute_destroyed "the management destroy is NOT reached after an unanswerable query"
refute_out "no child cluster" "an unanswered query is not reported as 'no child cluster'"
refute_out "fleet-down complete" "it does not report success"
expect_out "connection refused" "and it quotes what the provider actually said"

# The OTHER failure, which means the opposite. A management with no CAPI has no
# children BY DEFINITION, and every cluster this release builds is that shape.
# Refusing here made --force-no-edges mandatory on all of them, and the cost of
# that refusal is a cloud left billing — paid twice on 2026-08-19, on a teardown
# that was itself trying to stop the bill. NO FLAG is needed now.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t1\terror: the server doesn't have a resource type \"clusters\"\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 0 "absent CAPI CRDs proceed on their own, with no flag"
expect_out "no CAPI CRDs" "it says why it is allowed to continue"
expect_destroyed "the management destroy IS reached"
expect_out "fleet-down complete" "it reports success"

# …and the flag stays accepted, because the skill, CI and the printed
# next-step command all still pass it. It must not become an error.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t1\terror: the server doesn't have a resource type \"clusters\"\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes --force-no-edges
expect_rc 0 "--force-no-edges is still accepted and still proceeds"

# The command it PRINTS must be one it will itself accept. The flags were
# hard-coded, so on a cluster whose CAPI CRDs are absent it told the operator to
# run a line that step 1 then refused — measured 2026-08-19 on a real teardown,
# twice, before anyone suspected the instruction rather than the cluster.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t1\terror: the server doesn't have a resource type \"clusters\"\n"
run "$FLEET_DOWN" stubcloud --plan --force-no-edges
# Anchored on the ORDER, not on the flag: step 1 already prints the word
# --force-no-edges in its own message, so a bare substring test passes whether
# the fix is there or not. This one only matches the printed command line.
expect_out ".tfplan --force-no-edges --yes" "the next-step command carries the flag it was given"
refute_out ".tfplan --yes" "and does not print the line it would itself refuse"


# The other side of the same coin: the query worked and there is genuinely
# nothing. This must proceed, or the fail-safe above is just a script that
# never works.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t0\t\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 0 "an empty-but-successful enumeration proceeds"
expect_out "no child cluster" "it says 'no child cluster'"
expect_destroyed "the management destroy IS reached"
if grep -q '^infra-down ' "$STUB_TASK_LOG"
  then ok "it is 'task destroy' that ran"
  else bad "task ran, but not infra-down: $(tr '\n' ';' <"$STUB_TASK_LOG")"
fi

# Same run, checked for the CRD collision.
expect_log 'get clusters\.cluster\.x-k8s\.io -A' "the enumeration is group-qualified"
refute_log "$UNQUALIFIED" "no unqualified 'cluster' query in the enumeration path"

echo
echo "=== fleet-down: the destroy retries a race, and stops ==="

# Outscale, 2026-08-16: two passes died on "Subnet is in use. It has NICs" and
# "A load balancer is present on Net" while the provider API already reported
# zero instances, zero LBs and zero NICs. The plan ran ahead of the provider's
# own deletions. A retry fixes that; a retry that hides a permanent failure, or
# one that never stops, would be worse than the race.
export STUB_TASK_COUNT_FILE="$STUB_DIR/task.count"
export DESTROY_BACKOFF=0
# `infra-down`, not `destroy`: the target was renamed and the alias would let a
# harness keyed on the old name pass while asserting nothing.
destroys() { grep -c '^infra-down ' "$STUB_TASK_LOG" 2>/dev/null || echo 0; }
expect_destroys() { # <n> <label>
  local got; got="$(destroys)"
  if [ "$got" = "$1" ]; then ok "$2"; else bad "$2 (ran $got destroy/destroys, expected $1)"; fi
}

plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t0\t\n"

# 1. Transient, the case that actually happened.
: >"$STUB_TASK_COUNT_FILE"
export STUB_TASK_FAIL_TIMES=2
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 0 "two failed destroys then a success still completes the teardown"
expect_out "attempt 3/3" "it names the attempt that succeeded"
expect_destroys 3 "it retried exactly twice"
expect_out "fleet-down complete" "it reports success once the destroy worked"

# 2. Permanent. The retry must not turn a real failure into a green run — this
#    script reporting success over surviving resources is the billing defect its
#    own header is about.
: >"$STUB_TASK_COUNT_FILE"
export STUB_TASK_FAIL_TIMES=99
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 1 "a destroy that never succeeds still fails the run"
expect_out "after 3 attempt(s)" "it says how many attempts it made"
refute_out "fleet-down complete" "it does not report success after exhausting the retries"
expect_destroys 3 "it stops at DESTROY_ATTEMPTS instead of looping"

# 3. Permanent AND not ours. A managed load balancer that never finished
#    provisioning holds a port inside the customer subnet and cannot be deleted
#    by anyone but the provider — so subnet, network and teardown all queue
#    behind it. Measured on Outscale 2026-08-16 and OVH 2026-08-18. Telling this
#    apart from a retryable race is the difference between a support ticket and
#    an afternoon of re-running: on 2026-08-18 the operator paid the afternoon.
for MSG in \
  "Error: A load balancer is present on Net 'vpc-0000'. The Internet service cannot be unlinked" \
  "Error: Cannot perform the action. The Subnet subnet-0000 is in use. It has NICs." \
  "Error: Invalid state PENDING_CREATE of loadbalancer resource 0000-1111"; do
  : >"$STUB_TASK_COUNT_FILE"
  export STUB_TASK_FAIL_TIMES=99 STUB_TASK_MSG="$MSG"
  run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
  expect_rc 1 "a provider-held teardown still fails the run"
  expect_out "this is not yours to fix" "it names the wedged load balancer: ${MSG:7:38}…"
  expect_out "support ticket" "and sends the operator to a ticket rather than a retry"
done
unset STUB_TASK_MSG

# 4. Permanent and ORDINARY. The verdict above must not fire on every failure —
#    a guard written for the pathological case has turned red on the normal one
#    three times in this repository.
: >"$STUB_TASK_COUNT_FILE"
export STUB_TASK_FAIL_TIMES=99 STUB_TASK_MSG="Error: quota exceeded for instances"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 1 "an ordinary failure still fails"
refute_out "this is not yours to fix" "it does NOT blame the provider for an ordinary failure"
expect_out "INCOMPLETE" "it gives the ordinary message instead"
unset STUB_TASK_MSG

# 3. And it must not retry what worked: three destroys where one was needed is
#    three chances to destroy something that came back.
: >"$STUB_TASK_COUNT_FILE"
unset STUB_TASK_FAIL_TIMES
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 0 "a destroy that works first time completes"
expect_destroys 1 "it does not retry a destroy that succeeded"
refute_out "attempt" "no attempt counter is printed on the happy path"

unset STUB_TASK_COUNT_FILE DESTROY_BACKOFF

echo "=== fleet-down: an unreachable management is not a childless one ==="

plan 'no line matches, so cluster-info fails\t1\t\n'
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 1 "an unreachable management aborts"
refute_destroyed "it does not destroy a management it could not query"
expect_out "STOP" "it explains why it stopped"

# The operator can assert there is no child. That is a decision, not a default.
plan 'no line matches, so cluster-info fails\t1\t\n'
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes --force-no-edges
expect_rc 0 "--force-no-edges lets an unreachable management be destroyed"
expect_destroyed "the destroy is reached under --force-no-edges"

echo
echo "=== fleet-down: a child that did not go down blocks the management ==="

# fleet-down runs the real edge-down.sh here, so this covers the handoff too.
EDGE_LIST='get clusters.cluster.x-k8s.io -A\t0\tedge-a capi-clusters\n'
plan "${CLUSTER_INFO_OK}${EDGE_LIST}get clusters.cluster.x-k8s.io edge-a\t1\terror: You must be logged in to the server (Unauthorized)\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 1 "a child whose state is unknown aborts fleet-down"
refute_destroyed "the management is not destroyed while a child is unaccounted for"
expect_out "STOPPING before touching the management" "it names the child that blocked it"

plan "${CLUSTER_INFO_OK}${EDGE_LIST}get clusters.cluster.x-k8s.io edge-a\t1\tError from server (NotFound): clusters.cluster.x-k8s.io \"edge-a\" not found\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes
expect_rc 0 "a child already absent does not block fleet-down"
expect_destroyed "the destroy is reached once the child is accounted for"
if [ -s "$STUB_TOFU_LOG" ]
  then bad "something called tofu directly, bypassing the stubbed task"
  else ok "no direct tofu call: no run here can reach a cloud"
fi

echo
echo "=== edge-down: NotFound is absence, any other error is not ==="

plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io edge-b\t1\tError from server (NotFound): clusters.cluster.x-k8s.io \"edge-b\" not found\n"
run "$EDGE_DOWN" edge-b --yes
expect_rc 0 "NotFound exits 0"
expect_out "already absent" "NotFound reports 'already absent'"

# Same empty stdout, opposite meaning. Reporting absence here is what tells
# fleet-down the child is gone, and the management destroy follows.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io edge-b\t1\terror: You must be logged in to the server (Unauthorized)\n"
run "$EDGE_DOWN" edge-b --yes
expect_rc 1 "an authorization error exits non-zero"
refute_out "already absent" "an API error is NOT reported as absence"
expect_out "cannot tell whether" "it says the state is unknown"
refute_log '^delete ' "nothing is deleted while the state is unknown"

plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io edge-b\t1\tThe connection to the server was refused\n"
run "$EDGE_DOWN" edge-b --yes
expect_rc 1 "an unreachable API exits non-zero"
refute_out "already absent" "an unreachable API is NOT reported as absence"

echo
echo "=== edge-down: 'fully deleted' requires a provider that was checked ==="

# Shared prefix: the cluster exists, the cascade completes on the first poll.
# The --no-headers lines come FIRST — they are the narrower match.
GONE="${CLUSTER_INFO_OK}"
GONE+='get clusters.cluster.x-k8s.io edge-c -n capi-clusters --no-headers\t0\t\n'
GONE+='get machines -n capi-clusters -l cluster.x-k8s.io/cluster-name=edge-c --no-headers\t0\t\n'
GONE+='get clusters.cluster.x-k8s.io edge-c\t0\tedge-c Provisioned\n'
GONE+='get machines -n capi-clusters -l cluster.x-k8s.io/cluster-name=edge-c -o name\t0\tmachine.cluster.x-k8s.io/edge-c-cp-1\n'
GONE+='delete clusters.cluster.x-k8s.io edge-c\t0\tcluster.cluster.x-k8s.io "edge-c" deleted\n'
PROBE_MATCHES='get openstackcluster -n capi-clusters -o name\t0\topenstackcluster.infrastructure.cluster.x-k8s.io/edge-c\n'

# The probe matches nothing: no API was ever asked whether the VMs are gone.
# "fully deleted" here is the sentence that let billed resources survive.
plan "$GONE"
run "$EDGE_DOWN" edge-c --yes --timeout 30
refute_out "fully deleted" "an unidentified provider is never reported 'fully deleted'"
expect_rc 1 "an unidentified provider exits non-zero"
expect_out "could not tell which provider" "it says why nothing was verified"
if [ -s "$STUB_PY_LOG" ]
  then bad "it ran the verifier without knowing which provider to verify"
  else ok "the verifier is not run when there is no provider to run it for"
fi

# Positive control: with a provider AND a clean verification it may say it.
# Without this, the assertion above would also pass on a script that can never
# print 'fully deleted' at all.
plan "${GONE}${PROBE_MATCHES}"
STUB_PY_RC=0 run "$EDGE_DOWN" edge-c --yes --timeout 30
expect_rc 0 "a verified-clean provider exits 0"
expect_out "fully deleted" "a verified-clean provider IS reported 'fully deleted'"
if grep -q 'verify-provider-clean.py edge-c openstack' "$STUB_PY_LOG"
  then ok "the verifier is called for the probed provider"
  else bad "the verifier was not called as expected: $(cat "$STUB_PY_LOG")"
fi

# The verifier says resources remain. Kubernetes is clean, the invoice is not.
plan "${GONE}${PROBE_MATCHES}"
STUB_PY_RC=1 STUB_PY_OUT='leftover load balancer' run "$EDGE_DOWN" edge-c --yes --timeout 30
expect_rc 1 "a provider that still has resources exits non-zero"
refute_out "fully deleted" "leftover provider resources are not reported 'fully deleted'"
expect_out "Purge by hand" "it tells the operator to purge"

# Verification skipped (no credentials): exits 0, but must not claim more than
# it checked.
plan "${GONE}${PROBE_MATCHES}"
STUB_PY_RC=2 STUB_PY_OUT='no credentials in the environment' run "$EDGE_DOWN" edge-c --yes --timeout 30
expect_rc 0 "a skipped verification still exits 0"
refute_out "fully deleted" "a skipped verification does not claim 'fully deleted'"
expect_out "provider NOT re-checked" "it says the provider was not re-checked"

echo
echo "=== edge-down: a refused delete and a stuck cascade both fail loudly ==="

plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io edge-d\t0\tedge-d Provisioned\ndelete clusters.cluster.x-k8s.io edge-d\t1\tError from server: admission webhook denied the request\n"
run "$EDGE_DOWN" edge-d --yes --timeout 2
expect_rc 1 "a refused delete exits non-zero"
expect_out "REFUSED" "it says the delete was refused"
refute_out "objects gone" "a refused delete is not reported as a finished cascade"

# Nothing ever disappears: the safety net lifts finalizers and REPORTS, it does
# not declare victory. --timeout 2 keeps this short; sleep is stubbed.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io edge-e\t0\tedge-e Deleting\nget machines -n capi-clusters -l cluster.x-k8s.io/cluster-name=edge-e\t0\tedge-e-cp-1 Deleting\ndelete clusters.cluster.x-k8s.io edge-e\t0\tdeleted\n"
run "$EDGE_DOWN" edge-e --yes --timeout 2
expect_rc 1 "a cascade that never finishes exits non-zero"
refute_out "fully deleted" "a stuck cascade is not reported 'fully deleted'"
expect_out "MANUAL ACTION REQUIRED" "it asks for a manual check on the provider side"
# Same guarantee as fleet-down, in a run that deletes and patches by name.
refute_log "$UNQUALIFIED" "no unqualified 'cluster' verb in the delete/finalizer path"

echo

echo "=== the buckets it names must be the buckets that exist ==="

# Step 3 is a REPORT, and its whole value is that an operator can act on it. It
# interpolated cluster_name verbatim, so anyone who set a bucket_suffix — which
# docs/first-cluster.md step 3 tells every new user to do — or whose cluster_name
# contains a hyphen was handed names that do not exist.
mkdir -p "$STUB_DIR/root/infrastructure/opentofu/cluster/envs"
cat >"$ROOT/infrastructure/opentofu/cluster/envs/management-stubcloud.tfvars" <<'TFV'
cluster_name  = "example-dev"
bucket_suffix = "a1b2c3"
environment   = "dev"
TFV
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t0\t\n"
run "$FLEET_DOWN" stubcloud --plan-file "$STUB_DIR/d.tfplan" --yes --force-no-edges
rm -f "$ROOT/infrastructure/opentofu/cluster/envs/management-stubcloud.tfvars"
expect_out "s3-example-a1b2c3-stubcloud-tfstate-dev" \
  "the reported bucket keeps the suffix and the first segment only"
refute_out "s3-example-dev-stubcloud-tfstate-dev" \
  "it does not print the raw cluster_name, which names nothing"


echo "=== destroying takes TWO commands, and nothing may collapse them into one ==="

# The requirement: it must be IMPOSSIBLE to destroy in a single command. A macro
# that plans and applies internally puts the single line back one level up, so
# fleet-down enforces the two steps too.
plan "${CLUSTER_INFO_OK}get clusters.cluster.x-k8s.io -A\t0\t\n"
: >"$STUB_TASK_LOG"
run "$FLEET_DOWN" stubcloud --yes --force-no-edges
expect_rc 1 "no plan file: the teardown refuses"
expect_out "refusing to destroy without a plan you have read" "and says why"
expect_out "This takes two commands, always" "and names both"
[ ! -s "$STUB_TASK_LOG" ] && ok "…having called nothing at all" \
  || bad "it invoked something before refusing: $(tr '\n' ';' <"$STUB_TASK_LOG")"

# --yes is the confirmation flag and must NOT be a way past the plan requirement.
: >"$STUB_TASK_LOG"
run env TF_CLI_ARGS_destroy=-auto-approve "$FLEET_DOWN" stubcloud --yes --force-no-edges
expect_rc 1 "TF_CLI_ARGS_destroy does not buy a way past it either"
[ ! -s "$STUB_TASK_LOG" ] && ok "…still having called nothing" \
  || bad "an environment variable got past the plan requirement"

# --plan computes and STOPS.
: >"$STUB_TASK_LOG"
run "$FLEET_DOWN" stubcloud --plan --force-no-edges
expect_rc 0 "--plan succeeds"
expect_out "nothing was destroyed" "and says so plainly"
grep -q '^infra-down-plan ' "$STUB_TASK_LOG" && ok "it computed a destruction plan" \
  || bad "no plan was computed: $(tr '\n' ';' <"$STUB_TASK_LOG")"
grep -q '^infra-down ROLE' "$STUB_TASK_LOG" \
  && bad "--plan also applied it — that is the single command this forbids" \
  || ok "…and applied nothing"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
