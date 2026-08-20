#!/usr/bin/env bash
# Every jsonpath expression in the scripts, parsed by kubectl itself. Offline.
#
# On 2026-08-15 a gate meant to break a database deadlock could never fire,
# because its query used a NESTED filter:
#
#   items[?(@.status.conditions[?(@.type=='Ready')].status=='True')]
#
# kubectl answers "unterminated filter". The query therefore always failed, the
# substitution was always empty, and the condition it fed always read false. It
# passed eleven of eleven unit assertions — a stub answers the query it is
# asked and never evaluates the expression — and was caught only against a real
# deadlock on a paying cluster, at the end of three attempts.
#
# kubectl will parse an expression with no cluster at all: the parse error comes
# out before it ever tries to reach a server. So the discriminator is the
# MESSAGE, not the exit code — every expression "fails" offline, and only a
# malformed one fails with "error parsing jsonpath".
#
# Usage: check-jsonpath.sh [path ...]     (defaults to scripts/)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGETS=("${@:-$ROOT/scripts}")

command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl is required" >&2; exit 1; }

# OFFLINE means offline. --dry-run=client parses without a server, but kubectl
# still LOADS a kubeconfig — the ambient one, or ~/.kube/config — and once the
# cluster it names is gone it waits on a dead endpoint for every expression.
# On 2026-08-19 that hung the whole `task test-scripts` suite at its first
# harness, minutes after the clusters this file has nothing to do with were
# destroyed. Point it at a path that cannot exist so no server is ever dialled.
export KUBECONFIG=/dev/null

OBJ="$(mktemp)"; trap 'rm -f "$OBJ"' EXIT
cat >"$OBJ" <<'JSON'
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"jsonpath-probe"},
 "spec":{"containers":[{"name":"c","image":"i"}]}}
JSON

checked=0
bad=0

check_one() { # <file> <expression>
  local file="$1" expr="$2" err
  # Shell interpolation is not part of the jsonpath grammar: substitute a plain
  # token so `${name}` or `$ns` does not look like a syntax error.
  expr="$(printf '%s' "$expr" | sed -E 's/\$\{[^}]*\}/X/g; s/\$[A-Za-z_][A-Za-z0-9_]*/X/g')"
  checked=$((checked + 1))
  err="$(kubectl create -f "$OBJ" --dry-run=client --validate=false \
    -o jsonpath="$expr" 2>&1 >/dev/null)"
  case "$err" in
    *"error parsing jsonpath"* | *"unterminated"* | *"unrecognized character"* | *"invalid array index"*)
      printf '✗ %s\n    %s\n    %s\n' "$file" "$expr" "${err%%$'\n'*}" >&2
      bad=$((bad + 1))
      ;;
  esac
}

for target in "${TARGETS[@]}"; do
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Single- and double-quoted forms, one per line, deduplicated per file.
    while IFS= read -r expr; do
      [ -n "$expr" ] || continue
      check_one "${file#"$ROOT"/}" "$expr"
    done < <(grep -ohE "jsonpath='[^']*'|jsonpath=\"[^\"]*\"" "$file" 2>/dev/null |
      sed -E "s/^jsonpath=['\"]//; s/['\"]$//" | sort -u)
  done < <(find "$target" -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)
done

# A floor. Zero expressions is what this check reports when the extraction has
# gone blind — a quoting style it does not match, a directory that moved — and
# that must not read as "all clear". It is the failure mode of every check this
# repository has had to fix this week.
if [ "$checked" -eq 0 ]; then
  echo "✗ no jsonpath expression found — the extraction matched nothing, which verifies nothing" >&2
  exit 1
fi

if [ "$bad" -gt 0 ]; then
  echo >&2
  echo "✗ ${bad} of ${checked} jsonpath expression(s) cannot be parsed by kubectl." >&2
  echo "  A query kubectl cannot parse always fails, so whatever reads it always" >&2
  echo "  sees nothing — and nothing usually reads as 'fine'." >&2
  exit 1
fi

echo "✓ ${checked} jsonpath expression(s) parse"
