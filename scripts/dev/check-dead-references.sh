#!/usr/bin/env bash
# Nothing notices a path that stopped resolving — in a README, in a code
# comment, or worst, in a string a script prints at runtime. A comment is
# read once; a printed line is read on every run, then copy-pasted and
# answered "No such file or directory" (#118).
#
# lychee finds none of this: this repository writes commands as bare paths
# inside fences, not as Markdown links, and lychee reads neither code
# comments nor printed strings.
#
# Scope is deliberately narrow, the same lesson check-language.sh already
# paid for: a naive regex over ALL prose is unusable. `task [a-z-]+` alone
# gave ~45 false positives ("task is", "task and", "task was") against 3
# real ones — measured while scoping this file, `task` names hits a second,
# harder-to-bound ambiguity even restricted to comments and printed strings:
# `variables.tf` and `outputs.tf` both use "task infra" / "task
# register-spoke" as informal shorthand for a FUTURE, not-yet-built flow —
# flagging those would be wrong in the other direction, calling a design
# note a stale reference. So: PATHS only, and only inside a fenced code
# block, an inline `backtick span`, a code comment, or a printed string —
# never a plain sentence, and never a line that WRITES a path rather than
# reading it (a test fixture's own `printf ... >"$TMP/repo/foo.sh"`).
#
# .deadreferencesignore, if present, lists file:candidate pairs decided to be
# not-stale for a reason that regexes cannot see (a doc narrating a file's own
# removal, an illustrative example in a portable tool's own README) — scoped
# per-pair, not per-file, because both files it currently exempts also cite
# real paths that must stay checked. Same allowlist-not-silencer contract as
# .languageignore: an entry needs a reason above it.
#
# Usage: check-dead-references.sh [root-dir]   (default: repo root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" || exit 1

MISSING=0

# This checker and its test necessarily contain the very patterns they hunt —
# example paths in comments, and (in the test) synthetic fixture literals that
# trip the HCL heredoc-body scan by simply containing the string
# `description = <<-EOT`. Same self-exemption check-language.sh takes on
# itself, for the same reason: scanning either file finds only its own
# examples, never a stale reference in the rest of the tree.
self() { case "$1" in scripts/dev/check-dead-references.sh|scripts/dev/test-dead-references.sh) return 0 ;; esac; return 1; }

ignored() { # <file> <candidate>
  local file="$1" cand="$2" pattern
  [ -f "$ROOT/.deadreferencesignore" ] || return 1
  while IFS= read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    [ "$pattern" = "$file:$cand" ] && return 0
  done < "$ROOT/.deadreferencesignore"
  return 1
}

report() { # <file> <line> <reason>
  echo "✗ $1:$2: $3"
  MISSING=$((MISSING + 1))
}

# Repo-root-relative when it starts with a known top-level directory — that
# is how every citation in this repository is written. ${path.module}/...
# (Terraform's own way of saying "this file's directory") resolves relative
# to the FILE instead — the one true-but-relative path the issue names by
# example, and the reason this cannot just be "resolve everything from the
# repo root". `apps/` is a SEPARATE repository (OpenAether-apps, per
# CLAUDE.md) — never present in this checkout, so a reference into it is out
# of scope here, not a defect this check can see. A path this checkout would
# gitignore (envs/*.tfvars, kubeconfigs, ...) is meant to be created by the
# reader, not to exist yet — checked, not assumed absent.
resolve_path() { # <file> <candidate> -> 0 ok, 1 missing, 2 out of scope
  local file="$1" cand="$2" rel
  case "$cand" in
    '${path.module}'/*)
      rel="${cand#'${path.module}'/}"
      [ -e "$(dirname "$file")/$rel" ] && return 0 || return 1
      ;;
    apps/*) return 2 ;;
    # OpenAether-apps' own profile picker (README.md: "a modular pick from
    # OpenAether-apps (scripts/pick.py)") — cited bare, without an apps/
    # prefix, because it is invoked from that repo's own root. It does not
    # and cannot exist in this checkout.
    scripts/pick.py) return 2 ;;
    ./*) cand="${cand#./}" ;;
  esac
  case "$cand" in
    scripts/* | infrastructure/* | docs/* | .github/*)
      [ -e "$cand" ] && return 0
      git check-ignore -q "$cand" 2>/dev/null && return 2
      return 1
      ;;
    *)
      [ -e "$(dirname "$file")/$cand" ] && return 0 || return 1
      ;;
  esac
}

check_candidates() { # <file> <line-number> <text>
  local file="$1" line="$2" text="$3" m rc
  # A path: a token under a known root, ending in a plausible extension —
  # bounded so it cannot swallow trailing prose ("scripts/foo.sh and the").
  # A template placeholder ({{...}}, ${VAR}, <name>) is not a literal
  # reference and is excluded, ${path.module} aside (handled above).
  while read -r m; do
    [ -n "$m" ] || continue
    case "$m" in *'{{'*|'<'*|*'$'*'{'*) [ "${m#'${path.module}'}" = "$m" ] && continue ;; esac
    ignored "$file" "$m" && continue
    resolve_path "$file" "$m"; rc=$?
    [ "$rc" -eq 1 ] && report "$file" "$line" "no such path: $m"
  done < <(grep -oE '(\./)?(\$\{path\.module\}/)?(scripts|infrastructure|docs|apps|\.github)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' <<<"$text")
}

# --- Markdown: fenced blocks and inline `backtick spans`, never plain prose --
scan_markdown() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS=: read -r ln rest; do
      check_candidates "$f" "$ln" "$rest"
    done < <(awk '
      /^[[:space:]]*```/ { fence = !fence; next }
      fence { print NR ":" $0; next }
      {
        line = $0
        while (match(line, /`[^`]+`/)) {
          rest = substr(line, RSTART + RLENGTH)
          # `text`](https://...) is Markdown LINK TEXT for an external URL —
          # the href is the actual reference, the backtick span just happens
          # to look like a path (docs/emulated-cloud.md linking to feint
          # upstream docs/limits.md). Not a claim about this repository.
          if (rest !~ /^\]\(https?:\/\//) {
            print NR ":" substr(line, RSTART + 1, RLENGTH - 2)
          }
          line = rest
        }
      }' "$ROOT/$f")
  done < <(git ls-files '*.md')
}

# --- Code: comment lines and printed strings, the same prose check-language.sh
# already reads (heredoc `description = <<-EOT` bodies included) — minus any
# line that WRITES a path (a redirect target) rather than stating one; that
# is a test fixture building its own throwaway tree, not a claim about this
# repository's. ------------------------------------------------------------
scan_code() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    self "$f" && continue
    while IFS=: read -r ln rest; do
      check_candidates "$f" "$ln" "$rest"
    done < <(awk '
      /description[[:space:]]*=[[:space:]]*<<-?[A-Za-z_]+/ {
        match($0, /<<-?[A-Za-z_]+/)
        term = substr($0, RSTART, RLENGTH)
        sub(/^<<-?/, "", term)
        in_doc = 1
      }
      in_doc && $0 ~ ("^[[:space:]]*" term "[[:space:]]*$") { in_doc = 0; next }
      {
        comment = ($0 ~ /^[[:space:]]*(#|\/\/|\*)/)
        printed = (!comment && $0 ~ /((echo|print|printf|puts)[[:space:](]|(help|description)=)/)
        if (!comment && !printed && !in_doc) next
        if ($0 ~ /[^=]>>?[[:space:]]*["$'"'"'\/]/) next
        print NR ":" $0
      }' "$ROOT/$f")
  done < <(git ls-files '*.tf' '*.tftpl' '*.sh' '*.py')
}

scan_markdown
scan_code

if [ "$MISSING" -gt 0 ]; then
  echo
  echo "✗ ${MISSING} reference(s) to a path that does not resolve." >&2
  echo "  A comment is read once; a printed line is read on every run and then" >&2
  echo "  copy-pasted. Fix the reference, or delete the line if it is stale." >&2
  exit 1
fi
echo "OK — every path referenced in fenced code, backtick spans, comments and printed strings resolves."
