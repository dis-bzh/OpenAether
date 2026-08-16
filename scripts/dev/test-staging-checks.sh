#!/usr/bin/env bash
# Unit tests for the assertions that decide a staging run is GREEN, against a
# stub kubectl — same shape as test-rolling-replace.sh, one rung below the cloud.
#
# staging-verify.sh and staging-upgrade.sh are what turn "the apply returned"
# into "the cluster works", and every conclusion they reach comes out of a
# kubectl query. The class of defect that cost 25 to 90 minutes of paid cloud
# time each on 2026-08-15 was never the cloud: it was a query that FAILED and a
# counter that read the failure as zero. `grep -c` on empty input prints 0, and
# nothing downstream can tell that apart from "every node is on the target".
#
# So the input that matters here is a failing query, not a passing one. Each
# scenario overrides one line of an all-green plan and asks what the script
# concludes from it.
#
# A defect PROVEN in a script under test is reported as KNOWN DEFECT and does
# not redden the suite: this file owns the tests, not the scripts. The day one
# starts holding, `defect_gone` fails so the expectation is promoted to a hard
# assertion. STRICT_DEFECTS=1 makes them fatal now.
#
# Verdicts: ✓ pass, ✗ fail, ⏱ hang (the run never returned, so nothing was
# proven), — skip (the check never ran), ! known defect. Only ✓ is green.
#
# Usage: test-staging-checks.sh          (STRICT_DEFECTS=1, STRICT_SKIPS=1, RUN_TIMEOUT=<s>)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

REAL_SLEEP="$(command -v sleep)"; export REAL_SLEEP
REAL_KUBECTL="$(command -v kubectl || true)"

PASS=0 FAIL=0 KNOWN=0 SKIPPED=0 HUNG=0
# A run killed by the timeout comes back rc 124, and EVERY negative below is
# `[ "$RUN_RC" -ne 0 ]` — so a script that deadlocks scores as one that correctly
# refused. A hang proves nothing in either direction: it is its own verdict, and
# no conclusion drawn from a run that never returned may count as pass or fail.
RUN_HUNG=0 RUN_CMD=
hung() { printf '  \033[35m⏱\033[0m HANG %s\n' "$*"; HUNG=$((HUNG + 1)); }
from_hang() { # true (and reports) when the verdict comes from a run that never returned
  [ "$RUN_HUNG" = 1 ] || return 1
  hung "$1 — verdict void: '${RUN_CMD}' never returned, killed after ${RUN_TIMEOUT}s"
}
ok()   { from_hang "$*" && return 0; printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { from_hang "$*" && return 0; printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
# Counted, because "27 passed" reads identical whether 0 or 20 of them ran.
skip() { printf '  \033[34m—\033[0m SKIP %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
defect() { # a defect proven in the script under test, not fixed here
  from_hang "$*" && return 0
  printf '  \033[33m!\033[0m KNOWN DEFECT %s\n' "$*"
  KNOWN=$((KNOWN + 1)); [ "${STRICT_DEFECTS:-0}" = 1 ] && FAIL=$((FAIL + 1)); return 0
}
defect_gone() {
  from_hang "$*" && return 0
  printf '  \033[35m^\033[0m FIXED: %s — promote this to a hard assertion\n' "$*"; FAIL=$((FAIL + 1))
}

# --- the stubs ----------------------------------------------------------------
# One stub serves kubectl, task and flux, keyed on "<name> <argv>", so a single
# plan file drives a whole run. STUB_PLAN is "match<TAB>rc<TAB>stdout" lines; the
# first line whose match is a substring of the argv wins, no match = rc 1 and
# silence. In stdout, %% is a newline and @@ a tab (the plan is tab-delimited,
# and two of these queries legitimately return a tab-separated list).
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
argv="$(basename "$0") $*"
printf '%s\n' "$argv" >>"${STUB_LOG:-/dev/null}"
[ -f "${STUB_PLAN:-}" ] || exit 1
while IFS=$'\t' read -r match rc out; do
  [ -n "$match" ] || continue
  case "$argv" in
    *"$match"*)
      out="${out//%%/$'\n'}"; out="${out//@@/$'\t'}"
      # Results on stdout, diagnostics on stderr, like the real thing: a script
      # that reads an error message as data is exactly what we are hunting.
      if [ "${rc:-0}" = 0 ]; then
        [ -n "$out" ] && printf '%b\n' "$out"
      else
        [ -n "$out" ] && printf '%b\n' "$out" >&2
      fi
      exit "${rc:-0}"
      ;;
  esac
done <"$STUB_PLAN"
exit 1
STUB
chmod +x "$STUB_DIR/kubectl"
ln -s kubectl "$STUB_DIR/task"
ln -s kubectl "$STUB_DIR/flux"

# Time is the one thing a wait loop must not really spend here. Log the request,
# then yield briefly — a pure no-op spins staging-upgrade's background probe hot.
cat >"$STUB_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
printf 'sleep %s\n' "$1" >>"${STUB_LOG:-/dev/null}"
exec "$REAL_SLEEP" 0.02
STUB
chmod +x "$STUB_DIR/sleep"
export PATH="$STUB_DIR:$PATH"

STUB_PLAN="$STUB_DIR/plan"; export STUB_PLAN
STUB_LOG="$STUB_DIR/calls";  export STUB_LOG

# --- a fake repository root ----------------------------------------------------
# Both scripts derive ROOT from their own path, so a symlinked copy of the layout
# hands them fixture tfvars without going anywhere near envs/ — and still runs
# the real file, never a copy that can drift out of date.
PROVIDER=stubcloud ROLE=staging
GIT_REF='refs/tags/9.9.9-stub'
FAKE="$STUB_DIR/root"
CLUSTER="$FAKE/infrastructure/opentofu/cluster"
TFVARS="$CLUSTER/envs/${ROLE}-${PROVIDER}.tfvars"
mkdir -p "$FAKE/scripts/dev" "$CLUSTER/envs"
ln -s "$ROOT/scripts/dev/staging-verify.sh" "$FAKE/scripts/dev/staging-verify.sh"
ln -s "$ROOT/scripts/dev/staging-upgrade.sh" "$FAKE/scripts/dev/staging-upgrade.sh"
VERIFY="$FAKE/scripts/dev/staging-verify.sh"
UPGRADE="$FAKE/scripts/dev/staging-upgrade.sh"
KEYFILE="$STUB_DIR/ssh-key-fixture"; : >"$KEYFILE"

# The versions staging-upgrade upgrades TOWARD. Fictional on purpose: nothing in
# a fixture should read like a pin someone could copy into a real environment.
cat >"$CLUSTER/variables.tf" <<'TF'
variable "talos_version" {
  default = "v0.0.2"
}
variable "kubernetes_version" {
  default = "v0.0.2"
}
TF

tfvars() { # <talos> <k8s> — rewrite the fixture env file
  cat >"$TFVARS" <<EOF
talos_version      = "$1"
kubernetes_version = "$2"
git_ref            = "$GIT_REF"
EOF
}
tfvars v0.0.1 v0.0.1

# --- driving a run -------------------------------------------------------------
plan() { : >"$STUB_LOG"; printf '%b' "$*" >"$STUB_PLAN"; }
RUN_TIMEOUT="${RUN_TIMEOUT:-30}"
# `timeout 0` means NO timeout: the knob that exists to catch hangs would silently
# switch the catching off, and a hang would go back to being the CI job's own.
[ "$RUN_TIMEOUT" -gt 0 ] 2>/dev/null ||
  { echo "RUN_TIMEOUT must be a positive integer (0 disables the hang guard)" >&2; exit 2; }
run() { # <cmd...> — RUN_OUT gets stdout+stderr, RUN_RC the status
  : >"$STUB_LOG"; RUN_HUNG=0; RUN_CMD="$*"
  # To a file, not a pipe: staging-upgrade leaves a background probe holding the
  # inherited stdout, and a command substitution would wait on it forever.
  # 30s is ten times the slowest scenario. -k: a script that swallows TERM must
  # still die here rather than become the CI job's own timeout.
  timeout -k 5 "$RUN_TIMEOUT" "$@" >"$STUB_DIR/out" 2>&1 && RUN_RC=0 || RUN_RC=$?
  # 124 = timed out, 137 = still there 5s after TERM. Nothing under test exits
  # with either on purpose, so both mean "it never returned".
  case "$RUN_RC" in 124 | 137) RUN_HUNG=1 ;; esac
  RUN_OUT="$(cat "$STUB_DIR/out")"
}
verify()  { run env FLUX_READY_TIMEOUT="${FLUX_READY_TIMEOUT:-2}" "$VERIFY" "$PROVIDER" "$ROLE"; }
# A real run rewrites the pins, so every scenario starts from a fresh env file a
# patch below the target — otherwise the second one aborts on "upgrades nothing"
# and each assertion after it silently measures the wrong run.
# FLUX_READY_TIMEOUT reaches the staging-verify.sh this script chains into at the
# end; without it that one waits out its 1500s default and the run dies on the
# harness timeout instead of on an assertion.
upgrade() { tfvars v0.0.1 v0.0.1; run env FLUX_READY_TIMEOUT=2 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"; }
said()    { case "$RUN_OUT" in *"$1"*) return 0 ;; esac; return 1; }
called()  { grep -qF -- "$1" "$STUB_LOG"; }
# awk, not `grep -c`: this file exists because of what `grep -c` returns on input
# that never arrived.
# Keyed on the DURATION: staging-upgrade's background probe sleeps 1 the whole
# run, and counting those made "it kept waiting" true of a loop that never ran.
slept() { awk -v d="${1:-}" '/^sleep /{ if (d == "" || $2 == d) n++ } END{print n+0}' "$STUB_LOG"; }
# Call order. A call that never happened reads as "never" on the left and
# "first thing" on the right, so an order check over a missing call fails.
first_at() { awk -v pat="$1" 'index($0,pat){n=NR; exit} END{print (n ? n : 999999)}' "$STUB_LOG"; }
last_at()  { awk -v pat="$1" 'index($0,pat){n=NR} END{print n+0}' "$STUB_LOG"; }

# Every query staging-verify makes, all answered green. Scenarios prepend the one
# line they want to change, because the first match wins.
VERIFY_OK='get --raw=/readyz\t0\tok\n'
VERIFY_OK+='get nodes --no-headers\t0\tnode-a Ready control-plane 9m v0.0.1%%node-b Ready <none> 9m v0.0.1\n'
VERIFY_OK+='flux check\t0\t\n'
VERIFY_OK+='k8s-app=cilium\t0\tcilium-aaaaa 1/1 Running 0 9m%%cilium-bbbbb 1/1 Running 0 9m\n'
VERIFY_OK+='conditions[?(@.type=="Ready")]\t0\tnamespaces@@True%%sources@@True\n'
VERIFY_OK+='spec.suspend==true\t0\t\n'
VERIFY_OK+='get httproute longhorn\t1\tError from server (NotFound): httproutes "longhorn" not found\n'
VERIFY_OK+="get gitrepository openaether\t0\t${GIT_REF}\n"
VERIFY_OK+='task \t0\t\n'

# Nodes and kubelets already on the target, for staging-upgrade.
UPGRADE_OK='nodeInfo.kubeletVersion\t0\tv0.0.2%%v0.0.2\n'
UPGRADE_OK+='nodeInfo.osImage\t0\tTalos (v0.0.2)%%Talos (v0.0.2)\n'

echo "=== staging-verify: an unanswered query must not read as a healthy cluster ==="

plan "$VERIFY_OK"
verify
# The control every negative below depends on. Without it, "the script never said
# it was ready" is satisfied just as well by a harness that never ran the script.
{ [ "$RUN_RC" -eq 0 ] && said '2 node(s) Ready' && said 'all 2 Flux Kustomizations Ready' \
  && said 'no Kustomization is suspended' && said "tracked at ${GIT_REF}"; } \
  && ok "an all-green cluster passes, and the harness reaches every check" \
  || bad "the all-green control does not pass (rc=$RUN_RC) — every assertion below is meaningless until it does"

plan "get nodes --no-headers\t1\tError from server (Forbidden): nodes is forbidden\n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && ! said 'node(s) Ready'; } \
  && ok "a failing node query does not read as a Ready cluster" \
  || bad "a failing node query passed — 'no node is not-Ready' is not 'the nodes are Ready'"
# The five-minute bounded wait is a fiction as soon as the query ERRORS rather
# than returning an unready node: `TOTAL="$(kubectl … | wc -l)"` carries no
# `|| true`, pipefail makes it rc 1, and set -e exits AT the assignment.
if [ "$(slept 10)" -ge 25 ] && said 'not Ready after'; then
  defect_gone "the node wait now survives a transient query error"
else
  defect "staging-verify.sh:37 ends the run at the FIRST failed node query — $(slept 10) of the 30 retries, and not one word about nodes on stdout or stderr"
fi

plan "conditions[?(@.type==\"Ready\")]\t1\terror: the server could not find the requested resource\n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && ! said 'Flux Kustomizations Ready'; } \
  && ok "a failing Kustomization query does not read as a converged DAG" \
  || bad "a failing Kustomization query read as converged"
# Correct here is to keep polling until FLUX_READY_TIMEOUT and then say what
# stalled. `STATUS="$(kustomization_status)"` under `set -e` exits AT the
# assignment instead: one transient API error ends the run, silently.
if [ "$(slept 15)" -ge 1 ] && said 'not Ready after'; then
  defect_gone "the Kustomization wait now survives a transient query error"
else
  defect "staging-verify.sh:85 aborts the whole run on the FIRST failed Kustomization query — $(slept 15) retries, no message, rc=$RUN_RC"
fi

plan "conditions[?(@.type==\"Ready\")]\t0\t\n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && said '0 of 0 Kustomizations not Ready'; } \
  && ok "an EMPTY Kustomization list waits, then fails: zero is not converged" \
  || bad "an empty Kustomization list read as converged (rc=$RUN_RC)"

plan "conditions[?(@.type==\"Ready\")]\t0\tnamespaces@@True%%sources@@False\n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && said '1 of 2 Kustomizations not Ready' && said 'sources'; } \
  && ok "one stalled Kustomization fails the run, by name" \
  || bad "a stalled Kustomization passed — the Ready CONDITION is not being read"

plan "spec.suspend==true\t0\tflux-system/foundation-databases \n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && said 'suspended'; } \
  && ok "a suspended Kustomization fails the run (its Ready status is stale)" \
  || bad "a suspended Kustomization passed — a frozen DAG would read green"

plan "get httproute longhorn\t0\tlonghorn 9m\n${VERIFY_OK}"
verify
{ [ "$RUN_RC" -ne 0 ] && said 'no authN'; } \
  && ok "a published Longhorn HTTPRoute fails the run" \
  || bad "the unauthenticated storage UI passed the regression gate"

echo
echo "=== staging-verify: the apps ref is the one the tfvars asked for ==="

plan "get gitrepository openaether\t1\tError from server: connection refused\n${VERIFY_OK}"
verify
[ "$RUN_RC" -ne 0 ] && ok "an unresolvable ref fails the run" || bad "no ref at all passed"

# What a fix would compare against — read from the tfvars, the way the script
# does not. `refs/tags/X` on the object, or `X` when Flux fills ref.tag alone.
PINNED="$(grep -E '^[[:space:]]*git_ref[[:space:]]*=' "$TFVARS" | sed -E 's/.*"([^"]+)".*/\1/')"
plan "get gitrepository openaether\t0\tmain\n${VERIFY_OK}"
verify
if [ "$RUN_RC" -ne 0 ] && said 'main'; then
  defect_gone "the ref check now compares against git_ref (${PINNED})"
else
  defect "staging-verify.sh:124 only asserts the ref is NON-EMPTY: the cluster tracks branch 'main' while the tfvars pins '${PINNED}', and the run ends green"
fi

echo
echo "=== staging-upgrade: resolving the target, without a cluster ==="

tfvars v0.0.1 v0.0.1
plan "$VERIFY_OK"
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -eq 0 ] && said '+talos_version      = "v0.0.2"' && said '+kubernetes_version = "v0.0.2"'; } \
  && ok "the target comes from cluster/variables.tf and both pins are rewritten" \
  || bad "the dry run did not rewrite both pins (rc=$RUN_RC)"
grep -q 'v0.0.1' "$TFVARS" && ok "…on a COPY: the env file itself is untouched" \
  || bad "DRY_RUN=1 rewrote the real tfvars"

tfvars v0.0.2 v0.0.2
run env DRY_RUN=1 "$UPGRADE" "$PROVIDER" "$ROLE" "$KEYFILE"
{ [ "$RUN_RC" -ne 0 ] && said 'upgrade nothing'; } \
  && ok "a run that would upgrade nothing FAILS instead of quietly passing" \
  || bad "a no-op upgrade ended green — indistinguishable from one that worked"

echo
echo "=== staging-upgrade: the two version counters ==="

tfvars v0.0.1 v0.0.1
plan "${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -eq 0 ] && said 'every kubelet on v0.0.2' && said 'every node on Talos v0.0.2' \
  && said 'plan empty after the upgrade'; } \
  && ok "an upgrade whose nodes report the target passes end to end" \
  || bad "the all-green upgrade control does not pass (rc=$RUN_RC)"
called 'task talos-image PROVIDER=stubcloud VERSION=v0.0.2 ENSURE=1' \
  && ok "the Talos image is ensured for the TARGET version" \
  || bad "task talos-image was not called with the target version"
{ [ "$(first_at 'task talos-image')" -lt "$(last_at 'task infra')" ]; } \
  && ok "…before the apply that needs the image data source to resolve" \
  || bad "the image was ensured after the apply, which is the plan failure it exists to avoid"
{ called '-- --cp-only --upgrade --yes' && called '-- --workers-only --upgrade --yes'; } \
  && ok "rolling-replace is driven non-interactively, control planes first" \
  || bad "rolling-replace was not called with --yes (an unattended lane would hang on its prompt)"

plan "nodeInfo.kubeletVersion\t0\tv0.0.2%%v0.0.1\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && said 'still not on v0.0.2'; } \
  && ok "ONE stale kubelet fails the run after the bounded wait" \
  || bad "a stale kubelet passed (rc=$RUN_RC)"
[ "$(slept 10)" -ge 25 ] && ok "…having actually retried, not judged on the first read" \
  || bad "the kubelet wait did not retry"

plan "nodeInfo.osImage\t0\tTalos (v0.0.2)%%Talos (v0.0.1)\n${UPGRADE_OK}${VERIFY_OK}"
upgrade
{ [ "$RUN_RC" -ne 0 ] && said 'not running Talos v0.0.2'; } \
  && ok "ONE node left on the old Talos fails the run" \
  || bad "a node still on the old Talos passed (rc=$RUN_RC)"

# The case both counters are built out of. kubectl fails, the pipeline yields no
# lines, `grep -cv … || true` prints 0, and 0 stale nodes reads as "all of them
# are on the target" — from a query that returned nothing at all.
plan "nodeInfo.kubeletVersion\t1\terror: unable to parse requirement\nnodeInfo.osImage\t1\terror: unable to parse requirement\n${VERIFY_OK}"
upgrade
if ! said 'every kubelet on v0.0.2'; then
  defect_gone "the kubelet wait no longer concludes from an unanswered query"
else
  defect "staging-upgrade.sh:146 announces 'every kubelet on v0.0.2' after a FAILED node query — grep -cvx counted 0 lines of nothing"
fi
if ! said 'every node on Talos v0.0.2'; then
  defect_gone "the Talos version assertion no longer concludes from an unanswered query"
else
  defect "staging-upgrade.sh:177 announces 'every node on Talos v0.0.2' after a FAILED node query — same grep -cv reading 0"
fi
if [ "$RUN_RC" -ne 0 ]; then
  defect_gone "an upgrade that could not read a single node now fails"
else
  defect "the whole upgrade ends green (rc=0) without one node version ever having been read"
fi

echo
echo "=== staging-upgrade: report_probe, the interruption budget ==="

RUN_HUNG=0  # nothing below concludes from a run(), so a prior hang must not void it
# Extracted rather than run: how many samples a background probe gets in a stub
# run is a timing accident, and the interesting input is a log that stayed empty.
eval "$(awk '/^report_probe\(\) \{/,/^\}/' "$ROOT/scripts/dev/staging-upgrade.sh")"
# `fail` must ABORT, as it does in the script. Returning 1 instead lets the rest
# of the function run and the LAST test decide — which quietly reported a probe
# gate as broken while a fixed one was under test.
fail() { echo "✗ $*"; exit 1; }
probe_ok() { ( report_probe ) >/dev/null; }
# shellcheck disable=SC2034  # both are read by the extracted function
PROBE_LOG="$STUB_DIR/probe"; MAX_PROBE_FAILS=15

# The awk range above is a text match on the script's FORMATTING. When it misses
# — `report_probe () {`, a reindented brace — eval defines nothing, report_probe
# is "command not found", and `probe_ok && bad … || ok …` takes the GREEN branch
# on rc 127. So the extraction is asserted before anything is concluded from it.
if ! declare -F report_probe >/dev/null; then
  bad "report_probe could NOT be extracted from staging-upgrade.sh — the checks below would have scored a pass from rc 127"
else
  printf 'ok\nok\nFAIL\nok\n' >"$PROBE_LOG"
  probe_ok && ok "3 samples, 1 FAIL, budget 15 → passes" || bad "a healthy probe failed"

  printf 'FAIL\n%.0s' {1..20} >"$PROBE_LOG"
  probe_ok && bad "20 FAIL against a budget of 15 passed" || ok "20 FAIL over a budget of 15 → fails"

  : >"$PROBE_LOG"
  if probe_ok; then
    defect "staging-upgrade.sh:127 reports '0 FAIL in 0 samples' and PASSES on an empty probe log — a probe that never ran proves the API stayed up"
  else
    defect_gone "report_probe now refuses to conclude from zero samples"
  fi
fi
unset -f fail probe_ok; unset -f report_probe 2>/dev/null || true

echo
echo "=== the jsonpath templates parse (real kubectl, no cluster) ==="

RUN_HUNG=0  # kubectl is driven directly here, not through run()
# The stub answers whatever the plan says, so it can never tell us the QUERY is
# wrong — and one of the 2026-08-15 defects was a filter kubectl cannot parse,
# which fails every time and returns nothing, which reads as "nothing wrong".
# `patch --local` runs the template through the same parser, offline.
if [ -z "$REAL_KUBECTL" ]; then
  skip "kubectl is not installed — the jsonpath templates went unchecked"
else
  cat >"$STUB_DIR/obj.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: fixture, namespace: flux-system}
spec: {suspend: true, ref: {name: refs/tags/9.9.9-stub}}
status:
  conditions: [{type: Ready, status: "True"}]
  nodeInfo: {kubeletVersion: v0.0.2, osImage: "Talos (v0.0.2)"}
YAML
  parses() { # <template> — true unless kubectl's jsonpath parser rejects it
    # Through a file, not a pipe: under pipefail the pipeline would report
    # kubectl's rc, not grep's, and every template would look accepted.
    "$REAL_KUBECTL" patch --local --type merge -f "$STUB_DIR/obj.yaml" -p '{}' \
      -o "jsonpath=$1" >/dev/null 2>"$STUB_DIR/jsonpath.err"
    ! grep -q 'error parsing jsonpath' "$STUB_DIR/jsonpath.err"
  }
  parses '{range .items[?(@.spec.suspend==true]}{end}' \
    && bad "an unterminated filter was accepted — this check cannot fail" \
    || ok "control: a malformed template IS rejected"
  templates() { # <file...> — every jsonpath template, whichever way it is quoted
    # Four shapes in the wild: single or double quotes, opening either before
    # the word jsonpath or after its `=`. An extractor that knows one of them is
    # blind to the rest and reports that blindness as "every template parses" —
    # the defect class this block exists for. What it cannot see, it cannot
    # check. (No literal template in this comment: check-jsonpath.sh reads it.)
    grep -ohE -e "jsonpath='[^']*'" -e "'jsonpath=[^']*'" "$@" |
      sed -E "s/^'?jsonpath='?//; s/'\$//"
    # A double-quoted shell string owns the backslash before " $ ` \ — strip
    # exactly those, so the template is what kubectl would receive. {"\n"} stays.
    grep -ohE -e 'jsonpath="(\\.|[^"\\])*"' -e '"jsonpath=(\\.|[^"\\])*"' "$@" |
      sed -E 's/^"?jsonpath="?//; s/"$//; s/\\(["$`\\])/\1/g'
  }
  # Read out of the scripts, so a template added tomorrow is covered too — and
  # from all THREE, staging-idempotency.sh included.
  TPL_FILES=("$ROOT/scripts/dev/staging-verify.sh" "$ROOT/scripts/dev/staging-upgrade.sh"
    "$ROOT/scripts/dev/staging-idempotency.sh")
  n_tpl=0
  while read -r tpl; do
    [ -n "$tpl" ] || continue
    n_tpl=$((n_tpl + 1))
    # A `$VAR` survives extraction as literal text, and kubectl ACCEPTS literal
    # text — so parsing it would mint a green tick for a template never read.
    if [[ $tpl =~ \$[A-Za-z_{] ]]; then
      skip "built from a shell variable, so it was never parsed: $tpl"; continue
    fi
    # `{range}` with no `{end}` PARSES and then prints nothing — the same "the
    # query came back empty, so nothing is wrong" class. It is also what a
    # template split over a line continuation looks like to the extractor.
    case "$tpl" in
      *'{range'*'{end}'*) ;;
      *'{range'*) bad "unterminated {range}: parses, selects nothing, reads as clean: $tpl"; continue ;;
    esac
    parses "$tpl" && ok "parses: ${tpl:0:56}…" || bad "kubectl cannot parse: $tpl"
  done < <(templates "${TPL_FILES[@]}" | sort -u)
  # A COVERAGE floor, not a zero floor: "> 0" still reads green when the extractor
  # sees five uses out of six. Count what the files ASK for and demand as many
  # back, so a quoting style nobody anticipated fails loudly instead of unchecked.
  n_used="$(grep -vhE '^[[:space:]]*#' "${TPL_FILES[@]}" | grep -ohE 'jsonpath[a-z-]*=' | grep -c . || true)"
  n_raw="$(templates "${TPL_FILES[@]}" | grep -c . || true)"
  { [ "$n_raw" -ge "$n_used" ] && [ "$n_tpl" -gt 0 ]; } \
    && ok "the extractor saw all ${n_used} jsonpath use(s): ${n_tpl} distinct template(s)" \
    || bad "the jsonpath extractor saw ${n_raw} of ${n_used} jsonpath use(s) — what it cannot see, it cannot check"
  # The filter itself, against data: parsing it is not selecting with it.
  got="$("$REAL_KUBECTL" patch --local --type merge -f "$STUB_DIR/obj.yaml" -p '{}' \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$got" = True ] && ok "the Ready-condition filter selects the condition, not the first one" \
    || bad "the Ready-condition filter selected '$got'"
fi

echo
printf '%s passed, %s failed, %s hung, %s skipped, %s known defect(s) in the scripts under test\n' \
  "$PASS" "$FAIL" "$HUNG" "$SKIPPED" "$KNOWN"
{ [ "$KNOWN" -eq 0 ] || [ "${STRICT_DEFECTS:-0}" = 1 ]; } ||
  printf 'known defects are reported, not fixed: this file owns the tests. STRICT_DEFECTS=1 makes them fatal.\n'
RC=0
[ "$FAIL" -eq 0 ] || RC=1
# A hang is red on its own: it means an assertion never got an answer to judge.
[ "$HUNG" -eq 0 ] || { printf 'NOT green: %s verdict(s) came from a run that never returned.\n' "$HUNG"; RC=1; }
# An assertion that did not run has proven nothing, so a run with skips is not
# "all passed" however many passed. Soft by default (kubectl may be absent).
[ "$SKIPPED" -eq 0 ] || {
  printf 'NOT fully green: %s check(s) were SKIPPED and proved nothing. STRICT_SKIPS=1 makes them fatal.\n' "$SKIPPED"
  [ "${STRICT_SKIPS:-0}" = 1 ] && RC=1
}
exit "$RC"
