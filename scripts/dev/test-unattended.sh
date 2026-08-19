#!/usr/bin/env bash
# ==============================================================================
# A journey advertised as unattended must be unattended all the way down.
#
# `cluster-up … APPROVE=auto` gated once, applied phase 1 — fifty billed resources —
# then called bootstrap-phase2 WITHOUT passing APPROVE down. Phase 2 ran a bare
# `tofu apply`, which asks "Do you want to perform these actions?", got EOF and
# died. Three paid deployments found that, one at a time, because no test reads
# the call graph. This one does.
#
# Offline: it parses Taskfile.yml. No cloud, no tofu, no account, no bill.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

# The call graph is a tree, not something grep can walk: a caller passes APPROVE in
# a `vars:` mapping two levels down from the task that needs it. python3+yaml is
# how the other checks read this file. It prints one verdict per line; the shell
# keeps the counting, so the summary matches every other harness here.
python3 - >"$OUT" <<'PY'
import re, yaml

with open('Taskfile.yml') as fh:
    TASKS = (yaml.safe_load(fh) or {}).get('tasks') or {}

R = []
def hdr(m): R.append(('hdr', m))
def ok(m):  R.append(('ok', m))
def bad(m): R.append(('bad', m))

# The unattended entry point, and the lanes that may not spend money: `local-*`
# is Talos in Docker and `feint-*` is an API emulator on loopback. Neither can
# bill, so they are held to "must not be able to prompt" rather than to the
# cloud lane's plan-then-apply-that-plan contract.
ENTRY = 'cluster-up'
def free_lane(name): return name.startswith(('local-', 'feint-'))

VARREF = re.compile(r'\{\{[^}]*?\.([A-Za-z_][A-Za-z0-9_]*)')

def key(k):
    # PyYAML reads YAML 1.1, where an UNQUOTED `YES:` key is the boolean true.
    # Normalising here measures what go-task sees; the spelling is asserted on
    # its own below.
    return 'YES' if k is True else ('NO' if k is False else str(k))

def blocks(t):
    """Every shell command string of a task, in order."""
    out = []
    for c in (t.get('cmds') or []):
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, dict):
            for k in ('cmd', 'defer'):
                if isinstance(c.get(k), str):
                    out.append(c[k])
    return out

def code(text):
    """Shell lines, as the shell would see them: continuations joined (an
    `-auto-approve` on the second line still belongs to the apply on the first),
    comments, heredoc bodies and console output dropped — `task cluster-up` in
    the help text or in an `echo` is documentation, not a call."""
    joined, buf = [], ''
    for raw in text.splitlines():
        s = raw.rstrip()
        if s.endswith('\\'):
            buf += s[:-1] + ' '
        else:
            joined.append(buf + s)
            buf = ''
    if buf:
        joined.append(buf)
    here = None
    for raw in joined:
        s = raw.strip()
        if here is not None:
            if s == here:
                here = None
            continue
        m = re.search(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)', s)
        if m:
            here = m.group(1)
        if s and not s.startswith('#') and not re.match(r'(echo|printf)\b', s):
            yield s

def segs(line):
    return [s.strip() for s in re.split(r'&&|\|\||[;|]', line) if s.strip()]

# --- what each task is ------------------------------------------------------
BODY = {n: "\n".join(blocks(t)) for n, t in TASKS.items() if isinstance(t, dict)}
APPROVE_AWARE = {n for n, b in BODY.items() if 'APPROVE' in VARREF.findall(b)}

def alternatives(name):
    """Vars other than APPROVE that the callee's own gate accepts instead. Read from
    the gate itself: infra-apply refuses unless PLAN or APPROVE is given, so a caller
    handing it a plan file it has already read is not forgetting anything."""
    alts = set()
    for line in BODY[name].splitlines():
        s = line.strip()
        if re.match(r'(if|elif)\b', s) and re.search(r'\{\{[^}]*\.APPROVE', s):
            alts |= {v for v in VARREF.findall(s) if v != 'APPROVE'}
    return alts

def callers():
    """(caller, callee, how, vars) for all three call forms — the `- task:` list
    entry, a `deps:` entry, and a `task <name> VAR=…` line in a shell block. A
    call form nobody reads is where the next one of these will hide."""
    for name, t in TASKS.items():
        if not isinstance(t, dict):
            continue
        for how, entries in (('task:', t.get('cmds') or []), ('deps', t.get('deps') or [])):
            for c in entries:
                if isinstance(c, str):
                    if how == 'deps':
                        yield name, c, how, {}
                elif c.get('task'):
                    yield name, c['task'], how, {key(k): str(v) for k, v in (c.get('vars') or {}).items()}
        for line in code("\n".join(blocks(t))):
            for seg in segs(line):
                m = re.match(r'task\s+([A-Za-z0-9:._-]+)(.*)', seg)
                if m:
                    kv = dict(re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=(\S*)', m.group(2)))
                    yield name, m.group(1), 'shell', kv

# `tofu [-chdir=…] apply …` — flags with a separate value must not be mistaken
# for the plan file, which is the whole distinction being measured.
APPLY = re.compile(r'^tofu\b((?:\s+-\S+)*)\s+apply\b(.*)$')
TAKES_VALUE = {'-var', '-var-file', '-target', '-replace', '-state', '-parallelism', '-lock-timeout'}

REDIR = re.compile(r'^\d*(?:>>|>|<)')

def words(args):
    """Arguments as the command receives them: a redirection is the shell's, not
    the apply's. `2>&1` counted as a second positional once, and called a saved
    plan piped into tee an interactive apply."""
    out, drop = [], False
    for tok in args.split():
        if drop:
            drop = False
            continue
        m = REDIR.match(tok)
        if m:
            drop = tok == m.group(0)  # a bare `>` / `2>` / `<`: its target is the next word
            continue
        out.append(tok)
    return out

def classify(args):
    positional, flags, skip = [], set(), False
    for tok in words(args):
        if skip:
            skip = False
            continue
        if tok.startswith('-'):
            name = tok.split('=', 1)[0]
            flags.add(name)
            skip = name in TAKES_VALUE and '=' not in tok
        else:
            positional.append(tok)
    if '-auto-approve' in flags:
        return 'auto-approve'
    if len(positional) == 1 and not ({'-var', '-var-file'} & flags):
        return 'saved-plan'
    return 'prompting'

def applies():
    for name in BODY:
        for line in code(BODY[name]):
            for seg in segs(line):
                m = APPLY.match(seg)
                if m:
                    yield name, seg, classify(m.group(2))

# --- A. the defect itself: APPROVE must survive every call edge -----------------
hdr('APPROVE reaches every task whose body reads it')
edges = 0
for caller, callee, how, kv in callers():
    if callee not in APPROVE_AWARE or caller == callee:
        continue
    edges += 1
    alts = alternatives(callee)
    given = kv.get('APPROVE')
    if given is not None and (('.APPROVE' in given) or given.strip('"\'') == 'auto'):
        ok(f'{caller} → {callee} ({how}) carries APPROVE')
    elif given is not None:
        bad(f'{caller} → {callee} ({how}) passes APPROVE={given!r} — it hard-codes an answer instead of forwarding the operator\'s')
    elif alts & set(kv):
        ok(f'{caller} → {callee} ({how}) gives {sorted(alts & set(kv))[0]}, which {callee}\'s own gate accepts instead of APPROVE')
    else:
        want = ' or '.join(sorted(alts | {'APPROVE'}))
        bad(f'{caller} → {callee} ({how}) passes no {want} — {callee} stops for an approval nobody can answer, AFTER {caller} has already spent')

# --- B. how an apply is allowed to ask ---------------------------------------
hdr('every apply is a saved plan (cloud) or at least cannot prompt (free lanes)')
seen = {'cloud': 0, 'free': 0}
for name, seg, kind in applies():
    lane = 'free' if free_lane(name) else 'cloud'
    seen[lane] += 1
    short = re.sub(r'\s+', ' ', seg)[:70]
    if lane == 'cloud':
        if kind == 'saved-plan':
            ok(f'{name}: applies a saved plan — `{short}`')
        elif kind == 'auto-approve':
            bad(f'{name}: -auto-approve — nothing is frozen between the reading and the doing: `{short}`')
        else:
            bad(f'{name}: this apply asks "Do you want to perform these actions?" and dies on EOF unattended: `{short}`')
    else:
        if kind == 'prompting':
            bad(f'{name}: free lane, but this apply can still prompt: `{short}`')
        else:
            ok(f'{name}: free lane, and this apply cannot prompt ({kind})')

# --- C. a prompt must be skippable AND never attempted in the dark -----------
hdr('every question is guarded by APPROVE and by a terminal test')
prompts = 0
for name in BODY:
    if free_lane(name):
        continue
    for b in blocks(TASKS[name]):
        if not re.search(r'^\s*read\s+(-r\b|[A-Za-z_])', b, re.M):
            continue
        # A question is only this guard's business when it gates something that
        # SPENDS. Asked of every `read`, it reddened on a plain helper that
        # prompts for a value and runs nothing — the exact shape this repo has
        # been burned by three times: a guard that fails on correct work gets
        # muted, and then it protects nothing.
        if not re.search(r'\btofu\b', b) and not re.search(r'^\s*task\s+[a-z]', b, re.M):
            ok(f'{name} prompts, but that block spends nothing — not this guard\'s business')
            continue
        prompts += 1
        missing = [w for w, p in (('APPROVE', r'\{\{[^}]*\.APPROVE'), ('a terminal test ([ -t 0 ])', r'-t 0')) if not re.search(p, b)]
        if missing:
            bad(f'{name} prompts without {" and without ".join(missing)} — unattended it hangs or EOFs')
        else:
            ok(f'{name} prompts only with a terminal and without APPROVE')

# --- D. the var has to survive being read back -------------------------------
hdr('no task var is spelled as a YAML 1.1 boolean')
bools = []
for name, t in TASKS.items():
    if not isinstance(t, dict):
        continue
    for k in (t.get('vars') or {}):
        if isinstance(k, bool):
            bools.append(f'{name} vars')
    for c in (t.get('cmds') or []):
        if isinstance(c, dict):
            for k in (c.get('vars') or {}):
                if isinstance(k, bool):
                    bools.append(f'{name} → {c.get("task")} vars')
if bools:
    for b in sorted(set(bools)):
        bad(f'{b}: an unquoted YES/NO key. Any YAML 1.1 reader — this check included — sees `true`, not YES, and stops seeing the variable at all')
else:
    ok('no unquoted YES/NO key: a 1.1 reader and go-task agree on what the vars are called')

# --- E. the same forgotten-flag defect, one lane over ------------------------
# talos-image.sh has two applies: --ensure takes the -auto-approve branch, the
# plain path takes one that prompts. So the unattended entry must carry ENSURE.
hdr('the image build the entry point triggers is the non-interactive one')
img = [(callee, kv) for c, callee, _, kv in callers() if c == ENTRY and callee == 'image-build']
if not img:
    bad(f'{ENTRY} no longer calls image-build — this check is measuring a journey that moved')
for callee, kv in img:
    if kv.get('ENSURE', '').strip('"\''):
        ok(f'{ENTRY} → image-build carries ENSURE={kv["ENSURE"]}')
    else:
        bad(f'{ENTRY} → image-build passes no ENSURE — talos-image.sh then takes its prompt-capable apply')
    if '--ensure' in BODY.get('image-build', ''):
        ok('image-build forwards it to talos-image.sh as --ensure')
    else:
        bad('image-build does not forward --ensure — the ENSURE var is inert')

# --- F. floors: a check that measured nothing is not a green run -------------
hdr('the analysis actually found something to measure')
for label, n in (('tasks that read APPROVE', len(APPROVE_AWARE)), ('call edges into them', edges),
                 ('cloud-lane applies', seen['cloud']), ('guarded prompts', prompts)):
    ok(f'{n} {label}') if n else bad(f'ZERO {label} — the parser is broken, or the journey was renamed under it')

print("\n".join(f'{v}|{m}' for v, m in R))
PY
RC=$?
[ "$RC" -eq 0 ] || { echo "✗ the Taskfile could not be parsed (exit $RC) — nothing was checked" >&2; exit 1; }

while IFS='|' read -r verdict msg; do
  case "$verdict" in
    hdr) printf -- '--- %s ---\n' "$msg" ;;
    ok)  ok "$msg" ;;
    bad) bad "$msg" ;;
  esac
done <"$OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
