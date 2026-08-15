#!/usr/bin/env bash
# Find French prose where the repository says English is canonical.
#
# CLAUDE.md says "passer le détecteur" — and there was no detector, in either
# repository, which is why the 2026-07-28 switch left ~50 lines behind and a
# later audit still found seven whole files.
#
# Two things this gets right that the obvious version does not:
#
#   1. It does NOT key on accents. `preflight-quotas.py` says "DEPASSEMENT" and
#      two `ovh/*.tf` comments are accent-free French; an accent regex reports
#      them clean, which reads as "nothing there". Words, not diacritics.
#   2. It only reads prose — Markdown outside code fences, comment lines in
#      code, and the text of what a script PRINTS. A French word inside an
#      identifier or a non-printed literal is not a translation defect, and
#      flagging it would train people to ignore this.
#      The printed strings had to be added: on 2026-08-15 this file reported the
#      repository clean while a provisioner announced "▶ Purge du staging" to
#      every operator who built an Outscale image. A comment is read once; that
#      line is read every run.
#
# Usage: check-language.sh [path ...]        (defaults to the repository root)
#        check-language.sh --list            list the words it looks for
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Words chosen for one property: they are French and they are not English, not
# an identifier, and not a common abbreviation. That rules out the tempting ones
# — `son`, `car`, `pas`, `on`, `or`, `sur`, `main`, `distinct` — every one of
# which is an ordinary English word or appears in code.
#
# The list is necessarily incomplete, and every widening has found real lines
# that the narrower one called clean: `et ne pourrait ni` contained none of the
# first set, and sixteen `# Groupe NN` headers survived the second. Widen it
# again when you meet French this misses — and check the new words against BOTH
# repositories before committing, which is what caught `distinct`.
WORDS='le|la|les|des|une|dans|pour|avec|cette|être|est|sont|était|sera|qui|que|quand|ainsi|alors|aussi|avant|après|chaque|comme|depuis|donc|déjà|encore|entre|jamais|leur|mais|même|moins|notre|parce|peut|plutôt|puis|sans|sous|toujours|tout|toute|toutes|tous|très|vers|voici|voilà|faut|doit|doivent|ici|cela|ceci|celui|celle|nous|vous|elles|ils|du|au|aux|ni|elle|leurs|afin|lorsque|selon|plusieurs|ceux|celles|ensuite|enfin|pourrait|pourraient|publique|publiques|groupe|groupes|nom|noms|certificat|certificats|interne|internes|externe|externes|fichier|fichiers|exemple|exemples|attendu|attendue|ordinaire|ordinaires|racine|seule|seul|court|courte|observee|observée'

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; }
case "${1:-}" in
  --list) printf '%s\n' "$WORDS" | tr '|' '\n'; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

# .languageignore, if present, lists path prefixes this repository has decided
# are French on purpose — with the reason on the line above. It is an allowlist,
# not a silencer: everything not named in it is checked.
ignored() {
  local repo="$1" path="$2" pattern
  # This file, always and without an entry anywhere. It necessarily contains the
  # words it hunts — the list itself, and the sentence explaining `sans` versus
  # the SANs acronym. Relying on each repository to remember an allowlist line
  # meant the copy in the sibling repository failed its own CI on first run.
  [ "$path" = "scripts/dev/check-language.sh" ] && return 0
  [ -f "$repo/.languageignore" ] || return 1
  while read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    # Globbing is the point: an entry like `apps/base/*/README.md` must match.
    # shellcheck disable=SC2254
    case "$path" in $pattern) return 0 ;; esac
  done < "$repo/.languageignore"
  return 1
}

# Markdown: every .md that is not a .fr.md, minus vendored and generated trees.
md_files() {
  git -C "$1" ls-files '*.md' \
    | grep -v '\.fr\.md$' \
    | grep -vE '^(CHANGELOG\.fr|.*/vendor/|.*/node_modules/)'
}

# Code: the comment line of the four languages this repository writes.
code_files() { git -C "$1" ls-files '*.tf' '*.tftpl' '*.yaml' '*.yml' '*.sh' '*.py'; }

hits=0

scan_markdown() {
  local repo="$1" f
  while read -r f; do
    [ -n "$f" ] || continue
    ignored "$repo" "$f" && continue
    # awk rather than grep: a fenced block has to be skipped, and a French word
    # inside a shell example is not prose.
    awk -v words="$WORDS" -v file="$f" '
      /^[[:space:]]*```/ { fence = !fence; next }
      fence { next }
      {
        n = split(words, w, "|")
        for (i = 1; i <= n; i++) {
          cap = toupper(substr(w[i], 1, 1)) substr(w[i], 2)
          # Case-SENSITIVE, deliberately: `sans` is French, `SANs` is the
          # certificate acronym, and a case-insensitive match calls the second
          # one a translation defect on every TLS comment in the repository.
          if ($0 ~ ("(^|[^[:alnum:]_])(" w[i] "|" cap ")([^[:alnum:]_]|$)")) {
            printf "%s:%d: %s\n", file, NR, $0
            next
          }
        }
      }' "$repo/$f"
  done < <(md_files "$repo")
}

scan_code() {
  local repo="$1" f
  while read -r f; do
    [ -n "$f" ] || continue
    ignored "$repo" "$f" && continue
    awk -v words="$WORDS" -v file="$f" '
      # Two kinds of prose: comment lines (# for yaml/sh/py/tf, // and * for the
      # hcl/go style) and the text a script prints.
      {
        comment = ($0 ~ /^[[:space:]]*(#|\/\/|\*)/)
        printed = (!comment && $0 ~ /(echo|print|printf|puts)[[:space:](]/)
        if (!comment && !printed) next
        text = $0
        # In a printed line, a substitution is code, not prose: `du -h "$SNAP"`
        # inside an otherwise English message is the `du` command, and reporting
        # it as French is how a checker earns its way onto the ignore list.
        if (printed) { gsub(/\$\([^)]*\)/, " ", text); gsub(/\$\{[^}]*\}/, " ", text) }
        n = split(words, w, "|")
        for (i = 1; i <= n; i++) {
          cap = toupper(substr(w[i], 1, 1)) substr(w[i], 2)
          if (text ~ ("(^|[^[:alnum:]_])(" w[i] "|" cap ")([^[:alnum:]_]|$)")) {
            printf "%s:%d: %s\n", file, NR, $0
            next
          }
        }
      }' "$repo/$f"
  done < <(code_files "$repo")
}

repos=("${@:-$ROOT}")
for repo in "${repos[@]}"; do
  repo="$(cd "$repo" && pwd)"
  out="$( { scan_markdown "$repo"; scan_code "$repo"; } || true )"
  if [ -n "$out" ]; then
    # Prefix only when several repositories are in play: with one, it turns a
    # real path into one that does not exist.
    if [ "${#repos[@]}" -gt 1 ]; then
      # shellcheck disable=SC2001  # a per-line prefix, not a single substitution
      out="$(echo "$out" | sed "s|^|$(basename "$repo")/|")"
    fi
    echo "$out"
    hits=$(( hits + $(echo "$out" | wc -l) ))
  fi
done

if [ "$hits" -gt 0 ]; then
  echo
  echo "✗ $hits line(s) of French where English is canonical." >&2
  echo "  Translate them, or move the file to <name>.fr.md and write the English one." >&2
  exit 1
fi
echo "✓ no French found outside *.fr.md"
