#!/usr/bin/env bash
# Every tracked script must be reachable from something else in the tree — a
# task, a workflow, another script, or a document. A script git tracks and
# nothing else names is exactly the failure mode `task test-scripts` exists
# to catch, one level up: the check does the work, it is simply never asked
# (test-teardown.sh and test-cluster-checks.sh sat unreachable the same way
# until they were wired in).
#
# A plain basename match, deliberately: the reproduction in #116 is exactly
# `git grep -l <basename> -- . | grep -v ^<path>$`, and vulture cannot see
# this class of defect — it reasons inside a module, not across an
# invocation graph.
#
# Usage: check-script-reachability.sh [root-dir]   (default: repo root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" || exit 1

unreachable=0
while IFS= read -r f; do
  base="$(basename "$f")"
  if ! git grep -q -F -e "$base" -- . ":(exclude)$f" 2>/dev/null; then
    echo "✗ unreachable: $f"
    unreachable=$((unreachable + 1))
  fi
done < <(git ls-files '*.sh' '*.py')

if [ "$unreachable" -gt 0 ]; then
  echo
  echo "✗ ${unreachable} tracked script(s) are named by nothing else in the tree —"
  echo "  no task, workflow, script or document references them. Decide, for each:"
  echo "  wire it in, or delete it. A script nobody invokes is not coverage."
  exit 1
fi
echo "OK — every tracked script is reachable from something else in the tree."
