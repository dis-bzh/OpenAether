#!/usr/bin/env bash
# Cléa's own assertions, offline, on synthetic fixtures.
#
# Every check below has a twin that must FAIL — a reader that matches nothing, a
# writer that writes nothing, a datasource that answers 403. A check only ever
# seen to pass is a check nobody has tested; it is the shape behind more than
# twenty defects here, and Cléa exists to catch that shape in other files, so it
# does not get to ship with it.
#
# Fixtures are built here rather than committed: this repository is public, and
# a version fixture is one more file that can grow a real value.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEA="$ROOT/scripts/clea/clea.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# expect <rc> <label> -- <command...>   : the command must exit with exactly rc
expect() {
  local want="$1" label="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else
    bad "$label (exit $rc, wanted $want)"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -8
  fi
}

# says <label> <needle> -- <command...>  : the output must contain needle
says() {
  local label="$1" needle="$2"; shift 3
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then ok "$label"; else
    bad "$label — no '$needle' in the output"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -8
  fi
}

# --- a fixture repository, one anchor per supported value form ---------------
mkfixture() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts" "$d/.github/workflows" "$d/infra"
  cat > "$d/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
# clea-test: datasource=github-releases depName=acme/one extractVersion=^v(?<version>.*)$
ONE_VERSION="1.2.3"
# clea-test: datasource=github-releases depName=acme/two
TWO_VERSION="${TWO_VERSION:-v0.9.0}"
# clea-test: datasource=github-releases depName=acme/three
local THREE_VERSION="4.5.6"
EOF
  cat > "$d/.github/workflows/ci.yml" <<'EOF'
jobs:
  a:
    steps:
      - name: pip
        # clea-test: datasource=pypi depName=acme-four
        run: pip install acme-four==7.8.9
      - name: env
        env:
          # clea-test: datasource=github-releases depName=acme/five
          FIVE_VERSION: "10.11.12"
EOF
  cat > "$d/infra/variables.tf" <<'EOF'
variable "six" {
  # clea-test: datasource=github-releases depName=acme/six
  default = "v13.14.15"
}
EOF
  cat > "$d/Taskfile.yml" <<'EOF'
tasks:
  t:
    vars:
      # clea-test: datasource=github-releases depName=acme/seven
      SEVEN: '{{.SEVEN | default "16.17.18"}}'
EOF
  cat > "$d/clea.toml" <<'EOF'
[scan]
marker = "# clea-test:"
[report]
title = "t"
EOF
}

echo "=== the reader reads every form this repository actually uses ==="
mkfixture "$TMP/basic"
expect 0 "seven anchors in seven forms, all readable" \
  -- python3 "$CLEA" --root "$TMP/basic" coverage
says "the bash default form is read" "7 anchors, every one watched" \
  -- python3 "$CLEA" --root "$TMP/basic" coverage

echo
echo "=== an anchor inside a Markdown fence is an example, not a pin ==="
# Cléa's own README documents the anchor convention by showing one. Reading it
# reported go-task/task as an unwatched dependency of this repository — a
# detector matching its own documentation, which is the shape it hunts.
cp -r "$TMP/basic" "$TMP/md"
printf 'Docs.\n\n```bash\n# clea-test: datasource=github-releases depName=acme/documented\nDOC_VERSION="1.0.0"\n```\n' > "$TMP/md/README.md"
says "the fenced example is not counted" "7 anchors read" \
  -- python3 "$CLEA" --root "$TMP/md" coverage
expect 0 "and the tree is still clean" \
  -- python3 "$CLEA" --root "$TMP/md" coverage

echo
echo "=== an anchor that marks no version is a failure, with the reason ==="
mkdir -p "$TMP/tmpl"; cp "$TMP/basic/clea.toml" "$TMP/tmpl/"
cat > "$TMP/tmpl/Taskfile.yml" <<'EOF'
tasks:
  t:
    vars:
      # clea-test: datasource=github-releases depName=acme/computed
      PINNED:
        sh: ./compute-it.sh
      IMAGE: '{{.V | default .PINNED}}'
EOF
expect 1 "a template read as a version is refused" \
  -- python3 "$CLEA" --root "$TMP/tmpl" coverage
says "and it names what it read instead" "which is not a version" \
  -- python3 "$CLEA" --root "$TMP/tmpl" coverage

echo
echo "=== zero floor: nothing to check is not the same as nothing wrong ==="
mkdir -p "$TMP/empty"; cp "$TMP/basic/clea.toml" "$TMP/empty/"
echo "nothing here" > "$TMP/empty/README.md"
expect 1 "a tree with no anchor at all fails rather than reporting green" \
  -- python3 "$CLEA" --root "$TMP/empty" coverage

echo
echo "=== coverage against a Renovate config ==="
cp -r "$TMP/basic" "$TMP/cov"
cat > "$TMP/cov/renovate.json5" <<'EOF'
// A config that declares ONE manager, so six of the seven anchors are unwatched.
{
  customManagers: [
    {
      customType: "regex",
      fileMatch: ["^infra/variables\\.tf$"],
      matchStrings: [
        "# clea-test: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\s*\\n\\s*default\\s*=\\s*\"(?<currentValue>[^\"]+)\"",
      ],
    },
  ],
}
EOF
cat >> "$TMP/cov/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]
EOF
expect 1 "an inventory that sees one anchor of seven fails" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage
says "and names the six it cannot see" "renovate cannot see 6 of 7" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage
says "the config's own matchStrings are not counted as anchors" "7 anchors read" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage

# The other direction, which must go green: a manager wide enough to see them all.
cat > "$TMP/cov/renovate.json5" <<'EOF'
{
  customManagers: [
    { customType: "regex", fileMatch: [".*"],
      matchStrings: ["# clea-test: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)"] },
  ],
}
EOF
expect 0 "widening the manager to every anchor turns it green" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage

echo
echo "=== managerFilePatterns: /…/ is a regex, anything else a glob ==="
# Renovate renamed fileMatch and changed how it is read at the same time. A glob
# read as a regex matches almost nothing, so every anchor would be reported
# unwatched — and a checker that cries wolf gets muted, which is the failure
# this whole file is written against. No backslash in the patterns below: they
# would be eaten by the heredoc, and the assertion would test the escaping.
cp -r "$TMP/basic" "$TMP/mfp"
cat >> "$TMP/mfp/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]
EOF
mfp() { # <pattern>
  cat > "$TMP/mfp/renovate.json5" <<EOF
{
  customManagers: [
    { customType: "regex", managerFilePatterns: ["$1"],
      matchStrings: ["# clea-test: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[a-z0-9/-]+)"] },
  ],
}
EOF
}
mfp 'scripts/*.sh'
says "a bare pattern is a glob, and it reaches the shell script" \
  "renovate cannot see 4 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage
mfp '/^scripts/.+[.]sh$/'
says "slash-delimited is a regex, and reaches the same three" \
  "renovate cannot see 4 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage
mfp '^scripts/.+[.]sh$'
says "a regex written without its slashes reaches nothing, and says so" \
  "renovate cannot see 7 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage

echo
echo "=== a JSON5 config that does not parse stops the run ==="
cp -r "$TMP/cov" "$TMP/bad5"
printf '{ customManagers: [ { fileMatch: [".*"\n' > "$TMP/bad5/renovate.json5"
expect 1 "an unreadable inventory is an error, not an empty one" \
  -- python3 "$CLEA" --root "$TMP/bad5" coverage
says "and says which file" "renovate.json5" \
  -- python3 "$CLEA" --root "$TMP/bad5" coverage

echo
echo "=== bump: the inverse of the reader, and it refuses to write nothing ==="
cp -r "$TMP/basic" "$TMP/bump"
expect 0 "bump rewrites the pin" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/two v0.10.0
if grep -q 'TWO_VERSION:-v0.10.0' "$TMP/bump/scripts/install.sh"; then
  ok "the bash default form was rewritten in place"
else
  bad "the bash default form was not rewritten"
fi
expect 1 "bumping to the version already there is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/two v0.10.0
expect 1 "bumping an unknown dependency is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/nothing 1.0.0
expect 1 "bumping across a v prefix is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/three v9.9.9
expect 0 "extractVersion is applied on the way in" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/one v1.3.0
if grep -q 'ONE_VERSION="1.3.0"' "$TMP/bump/scripts/install.sh"; then
  ok "the stripped form was written, not the tag"
else
  bad "extractVersion was not applied: $(grep ONE_VERSION "$TMP/bump/scripts/install.sh" | head -1)"
fi

echo
echo "=== every site of one dependency, not the first ==="
cp -r "$TMP/basic" "$TMP/multi"
cat > "$TMP/multi/scripts/other.sh" <<'EOF'
# clea-test: datasource=github-releases depName=acme/three
OTHER_THREE="4.5.6"
EOF
python3 "$CLEA" --root "$TMP/multi" bump acme/three 4.6.0 >/dev/null 2>&1
if grep -q '4.6.0' "$TMP/multi/scripts/other.sh" && \
   grep -q '4.6.0' "$TMP/multi/scripts/install.sh"; then
  ok "both sites moved — one tool, one version, everywhere it is claimed"
else
  bad "only one of the two sites moved"
fi

echo
echo "=== the probe refuses rather than destroy or pretend ==="
# It bumps a pin and restores the tree with `git checkout -- .`. Run on a dirty
# tree that discards somebody's work, and a probe that cannot start a container
# must not exit 0 — a lane that reports success having run nothing is the whole
# failure this file is written against.
PROBE="$ROOT/scripts/clea/probe.sh"
git -C "$TMP/basic" init -q 2>/dev/null
git -C "$TMP/basic" add -A 2>/dev/null
git -C "$TMP/basic" -c user.email=t@t -c user.name=t commit -qm fixture 2>/dev/null
echo "dirty" >> "$TMP/basic/scripts/install.sh"
expect 1 "a dirty tree is refused before anything is touched" \
  -- env CLEA_ROOT="$TMP/basic" "$PROBE" acme/two v0.10.0 /bin/true "echo 0.10.0"
git -C "$TMP/basic" checkout -q -- .
if [ -n "$(git -C "$TMP/basic" status --porcelain --untracked-files=no)" ]; then
  bad "the refusal happened after the tree was already restored"
else
  ok "and the refusal came before the trap that would have discarded it"
fi
# PATH without docker: the container lanes cannot start, and that is a failure.
expect 1 "a probe that cannot start a container exits non-zero" \
  -- env CLEA_ROOT="$TMP/basic" PATH=/usr/bin:/bin "$PROBE" \
       acme/two v0.10.0 /bin/true "echo 0.10.0"

echo
echo "=== version comparison, and the pair every hand-rolled comparator gets wrong ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
checks = [
    ("1.13.10 > 1.13.9", clea.is_newer("1.13.9", "1.13.10")),
    ("v1.13.10 > v1.13.9", clea.is_newer("v1.13.9", "v1.13.10")),
    ("1.2.3 is not newer than itself", not clea.is_newer("1.2.3", "1.2.3")),
    ("a release beats its own rc", clea.is_newer("1.2.3-rc1", "1.2.3")),
    ("an rc does not beat the release", not clea.is_newer("1.2.3", "1.2.3-rc1")),
    ("shapes must agree", not clea.same_shape("1.2.3", "v1.2.3")),
    ("extractVersion strips the v", clea.apply_extract("v1.2.3", r"^v(?<version>.*)$") == "1.2.3"),
    ("no extractVersion keeps the tag", clea.apply_extract("v1.2.3", None) == "v1.2.3"),
]
bad = [name for name, got in checks if not got]
for name, got in checks:
    print(("  \033[32m✓\033[0m " if got else "  \033[31m✗\033[0m ") + name)
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 8)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a rate-limited datasource is an error, never 'up to date' ==="
python3 - "$CLEA" <<'PY'
import http.server, importlib.util, socket, sys, threading

spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 403 if "limited" in self.path else 200
        body = b'{"message":"API rate limit exceeded"}' if code == 403 else b'v9.9.9\n'
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
server = http.server.HTTPServer(("127.0.0.1", port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{port}"

failures = []
try:
    clea.http_get(f"{base}/limited")
    failures.append("a 403 did not raise")
except clea.CleaError as exc:
    if "GITHUB_TOKEN" not in str(exc):
        failures.append(f"the 403 message does not name the fix: {exc}")

got = clea.latest_url_text("k8s", None, url=f"{base}/ok",
                           extract=r"^(?P<v>v[0-9][0-9A-Za-z.-]*)$")
if got["tag"] != "v9.9.9":
    failures.append(f"url-text read {got['tag']!r}")
try:
    clea.latest_url_text("k8s", None, url=f"{base}/ok", extract=r"^(?P<v>NOPE)$")
    failures.append("an extract that matches nothing did not raise")
except clea.CleaError:
    pass
server.shutdown()
for f in failures:
    print("  \033[31m✗\033[0m " + f)
if not failures:
    print("  \033[32m✓\033[0m a 403 raises and names GITHUB_TOKEN")
    print("  \033[32m✓\033[0m url-text extracts, and refuses to invent a version")
sys.exit(1 if failures else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== the helm index: indent is the only structure a line scanner has ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
# Built from the real shape of https://helm.cilium.io/index.yaml, which is
# 1.7 MB and embeds Kubernetes CRD listings inside an annotation. Reading every
# `version:` line collected `v2` from depth 10, and (2,) outranks (1,20,1), so
# the newest chart of a repository serving 1.20 came back as v2. Following the
# annotation's own list items then re-based the scan and it came back 1.8.13.
# Both were seen against the live index before this fixture existed.
INDEX = b'''apiVersion: v1
entries:
  cilium:
  - annotations:
      artifacthub.io/crds: "- kind: CiliumNetworkPolicy\\n  version: v2\\n  name: x\\n"
      artifacthub.io/links: |
        - name: a
          version: v2
        - name: b
          version: v2
      artifacthub.io/prerelease: |
          version: 99.9.9
    apiVersion: v2
    appVersion: 1.20.1
    name: cilium
    version: 1.20.1
  - annotations:
      deep:
          version: v2
    apiVersion: v2
    version: 1.19.2
  - apiVersion: v2
    version: 1.21.0-rc.1
  - apiVersion: v2
    version: 1.8.13
  zzz-other-chart:
  - version: 99.0.0
'''
clea.http_get = lambda url, *a, **k: INDEX
got = clea.latest_helm("cilium", None, registry_url="https://example.invalid")["tag"]
checks = [
    ("v2 at depth 10 is not a chart version", got != "v2"),
    ("the annotation's own list items do not re-base the scan", got != "1.8.13"),
    ("1.20.1 beats 1.19.2, 1.8.13 and the rc", got == "1.20.1"),
    ("the next entry is not read", got != "99.0.0"),
    # Load-bearing on its own: 99.9.9 IS semver, so only the indent says no.
    ("a semver-shaped value at the wrong depth is not a chart version",
     got != "99.9.9"),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + f"{name} (got {got})")
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 5)); else FAIL=$((FAIL + 1)); fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
