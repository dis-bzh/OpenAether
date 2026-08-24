#!/usr/bin/env python3
"""Cléa — watch what a repository pins, and prove a bump before anyone merges it.

Generic on purpose: this file knows nothing about the repository it runs in.
Everything specific arrives through `clea.toml` and through the host repository's
own commands. Dropping it into another project is copying this directory and
writing a new `clea.toml`.

Standard library only — no `pip install` anywhere in the path, so it also runs
inside the bare container the probe lanes use.

Commands
--------
  coverage   offline. Every version anchor in the tree must be readable, and
             seen by every inventory declared in clea.toml. Exits 1 otherwise.
  scan       online. Resolve the latest upstream version of every dependency and
             write the state file plus a Markdown report.
  bump       rewrite one pin in place, by the exact inverse of the reader.
  report     render Markdown from a state file.
  prune      name the probe branches whose pin already landed on the base branch.

The two rules this file will not bend
-------------------------------------
* **Zero floor.** An extractor that matches nothing, a datasource that returns
  no version, a tree with no anchors: all exit 1. A green run that checked
  nothing is worse than no check, and it is the shape this repository keeps
  meeting.
* **Loud on rate limits.** An unauthenticated GitHub API call gets 60 requests
  an hour from a shared runner IP, which is what took a `main` branch red once
  here. A 401/403/429 is an error, never "no new version".
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - only on very old interpreters
    print("clea needs Python 3.11 or newer (tomllib)", file=sys.stderr)
    raise SystemExit(1)

USER_AGENT = "clea/1 (+https://github.com/dis-bzh/OpenAether-infra)"
SKIP_DIRS = {".git", "node_modules", ".terraform", ".terraform-validate", "vendor"}


class CleaError(Exception):
    """Anything that must stop the run rather than degrade into a green report."""


# ---------------------------------------------------------------------------
# JSON5, enough of it to read a Renovate config
# ---------------------------------------------------------------------------
# Renovate's own file is JSON5: comments, bare keys, single quotes, trailing
# commas. Parsing it matters because it is one of the inventories `coverage`
# compares against, and a parse that silently yields nothing would mark every
# anchor in the tree as unwatched — noise, which is how a checker gets muted.
# So this raises instead.

_J5_TOKEN = re.compile(
    r"""
      "(?:\\.|[^"\\])*"      # double-quoted string
    | '(?:\\.|[^'\\])*'      # single-quoted string
    | //[^\n]*               # line comment
    | /\*.*?\*/              # block comment
    | [\s\S]                 # anything else, one character
    """,
    re.VERBOSE | re.DOTALL,
)


def _requote(tok: str) -> str:
    """A single-quoted JSON5 string as a double-quoted JSON one."""
    body = tok[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            out.append(nxt if nxt == "'" else c + nxt)
            i += 2
            continue
        out.append('\\"' if c == '"' else c)
        i += 1
    return '"' + "".join(out) + '"'


def json5_to_json(text: str) -> str:
    """Rewrite JSON5 as JSON, leaving string contents untouched.

    Comments become a space so the characters around them stay in one run —
    otherwise a key introduced by `{` on one line and commented on the next
    would lose the `{` that identifies it as a key.
    """
    parts: list[str] = []
    run: list[str] = []

    def flush() -> None:
        if not run:
            return
        chunk = "".join(run)
        # bare keys -> quoted keys
        chunk = re.sub(r"([{,]\s*)([A-Za-z_$][\w$-]*)(\s*):", r'\1"\2"\3:', chunk)
        # trailing commas
        chunk = re.sub(r",(\s*[}\]])", r"\1", chunk)
        parts.append(chunk)
        run.clear()

    for m in _J5_TOKEN.finditer(text):
        tok = m.group(0)
        if tok.startswith("//") or tok.startswith("/*"):
            run.append(" ")
        elif tok.startswith('"'):
            flush()
            parts.append(tok)
        elif tok.startswith("'"):
            flush()
            parts.append(_requote(tok))
        else:
            run.append(tok)
    flush()
    return "".join(parts)


def load_json5(path: Path) -> dict:
    try:
        return json.loads(json5_to_json(path.read_text(encoding="utf-8")))
    except (OSError, ValueError) as exc:
        raise CleaError(f"cannot read {path} as JSON5: {exc}") from exc


# ---------------------------------------------------------------------------
# Anchors
# ---------------------------------------------------------------------------
# The inventory is the tree itself: the same `# renovate: datasource=… depName=…`
# comment Renovate reads, with the pinned value on one of the lines below it.
# One convention, not two — a second inventory is a second thing to drift.
#
# Where Renovate asks you to DECLARE the shape of the value (and ignores in
# silence anything you forgot to declare), Cléa RECOGNISES a fixed set of shapes
# and fails on one it cannot read. That difference is the whole point of
# `coverage`: Cléa's list is a superset, so what it sees and Renovate does not
# is exactly the set of pins nothing is watching.

# Built from the configured marker rather than hard-coded, and not only for
# other repositories: Cléa's own test fixtures carry anchors, so a hard-coded
# word makes the scanner find them and report acme/one as an unwatched
# dependency of this repository. A detector that matches its own fixtures is the
# defect this file is written against — silencing it by path would have hidden
# it instead of removing it.
def anchor_re(marker: str) -> re.Pattern[str]:
    token = marker.strip().lstrip("#/ ").rstrip(":").strip()
    if not token:
        raise CleaError("clea.toml: [scan] marker is empty")
    return re.compile(rf"^\s*(?:#|//)\s*{re.escape(token)}:\s*(?P<attrs>.*\S)\s*$")


ATTR_RE = re.compile(r"(\w+)=(\S+)")

# Ordered: the first form that matches the line wins, so the more specific
# shapes come first. `task-default` before the YAML forms, or a Taskfile's
# `KEY: '{{.KEY | default "1.2.3"}}'` reads back as the whole template.
VALUE_FORMS: list[tuple[str, re.Pattern[str]]] = [
    ("task-default", re.compile(r"\|\s*default\s+\"(?P<v>[^\"]+)\"")),
    ("bash-default", re.compile(
        r"^\s*(?:local\s+|export\s+)?[A-Za-z_]\w*=\"\$\{[A-Za-z_]\w*:-(?P<v>[^}\"]+)\}\"")),
    ("bash", re.compile(r"^\s*(?:local\s+|export\s+)?[A-Za-z_]\w*=\"(?P<v>[^\"]+)\"")),
    ("hcl-default", re.compile(r"^\s*default\s*=\s*\"(?P<v>[^\"]+)\"")),
    ("pip", re.compile(r"pip install\s+[A-Za-z0-9_.\-\[\]]+==(?P<v>[^\s\"']+)")),
    ("precommit-rev", re.compile(r"^\s*rev:\s*\S+\s*#\s*(?P<v>\S+)")),
    ("yaml-dq", re.compile(r"^\s*[A-Za-z_][\w.\-]*:\s*\"(?P<v>[^\"]+)\"")),
    ("yaml-sq", re.compile(r"^\s*[A-Za-z_][\w.\-]*:\s*'(?P<v>[^']+)'")),
    ("action-sha", re.compile(r"^\s*(?:-\s*)?uses:\s*\S+@\S+\s*#\s*(?P<v>\S+)")),
]

# How far below the anchor the value may sit. Renovate's own regexes allow one
# line; three covers a YAML `env:` key that opens its block on the next line.
VALUE_WINDOW = 3

# What a version is allowed to look like. Without this the YAML form reads a
# Taskfile's `KEY: '{{.VERSION | default .PINNED}}'` back as the version itself,
# and the anchor looks healthy while marking a template. A form that matches is
# not the same as a value that means something.
VERSION_LIKE = re.compile(r"^v?\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.+-]+)?$")


class Anchor:
    __slots__ = ("path", "line", "attrs", "value", "value_line", "form", "span",
                 "reason")

    def __init__(self, path: str, line: int, attrs: dict[str, str]) -> None:
        self.path = path
        self.line = line
        self.attrs = attrs
        self.value: str | None = None
        self.value_line: int | None = None
        self.form: str | None = None
        self.span: tuple[int, int] | None = None  # column span of the value
        self.reason: str = ""

    @property
    def dep(self) -> str:
        return self.attrs.get("depName", "?")

    @property
    def datasource(self) -> str:
        return self.attrs.get("datasource", "?")

    @property
    def key(self) -> tuple[str, int]:
        return (self.path, self.line)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<Anchor {self.path}:{self.line} {self.dep}={self.value}>"


def _read_value(lines: list[str], start: int):
    """First recognised version in the window under the anchor at index `start`.

    Returns (value, line, form, span) or (None, reason) — the reason names what
    was read instead, because "no value here" and "this line reads
    `{{.VERSION | default .PINNED}}`" send a reader to two different places.
    """
    rejected: list[str] = []
    for offset in range(1, VALUE_WINDOW + 1):
        idx = start + offset
        if idx >= len(lines):
            break
        line = lines[idx]
        if not line.strip():
            continue
        for form, pattern in VALUE_FORMS:
            m = pattern.search(line)
            if not m:
                continue
            value = m.group("v")
            if VERSION_LIKE.match(value):
                return value, idx + 1, form, m.span("v")
            rejected.append(f"line {idx + 1} reads {value!r} ({form}), which is not a version")
    return None, ("; ".join(rejected) if rejected
                  else f"nothing version-shaped in the {VALUE_WINDOW} lines below")


def _walk(root: Path, include: list[str], exclude: list[str]):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            full = Path(dirpath) / name
            rel = full.relative_to(root).as_posix()
            if any(fnmatch.fnmatch(rel, pat) for pat in exclude):
                continue
            if include and not any(fnmatch.fnmatch(rel, pat) for pat in include):
                continue
            yield rel, full


def scan_anchors(root: Path, marker: str, exclude: list[str],
                 include: list[str] | None = None) -> tuple[list[Anchor], list[Anchor]]:
    """Every anchor in the tree, split into readable and value-less.

    A value-less anchor is not a warning. It marks a version that is not there —
    a leftover from when the value was a literal, or a pin that moved elsewhere
    — so it can never be bumped and reads to a human as if it could.
    """
    found: list[Anchor] = []
    novalue: list[Anchor] = []
    pattern = anchor_re(marker)
    token = marker.strip().lstrip("#/ ").rstrip(":").strip()
    for rel, full in _walk(root, include or [], exclude):
        try:
            text = full.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if token not in text:
            continue
        lines = text.splitlines()
        # An anchor inside a fenced block of a Markdown file is an EXAMPLE, not
        # a pin — the same rule check-language.sh applies to prose. Without it
        # Cléa reports the anchor in its own README as an unwatched dependency
        # of the repository, which is the class of defect it exists to find.
        markdown = rel.endswith((".md", ".markdown"))
        fenced = False
        for i, line in enumerate(lines):
            if markdown and line.lstrip().startswith(("```", "~~~")):
                fenced = not fenced
                continue
            if fenced:
                continue
            m = pattern.match(line)
            if not m:
                continue
            attrs = dict(ATTR_RE.findall(m.group("attrs")))
            if "depName" not in attrs:
                continue
            anchor = Anchor(rel, i + 1, attrs)
            got = _read_value(lines, i)
            if got[0] is None:
                anchor.reason = got[1]
                novalue.append(anchor)
                continue
            anchor.value, anchor.value_line, anchor.form, anchor.span = got
            found.append(anchor)
    found.sort(key=lambda a: a.key)
    novalue.sort(key=lambda a: a.key)
    return found, novalue


# ---------------------------------------------------------------------------
# Inventories to cross-check against
# ---------------------------------------------------------------------------

def _file_matcher(pattern: str):
    """Renovate's managerFilePatterns rule: /…/ is a regex, anything else a glob."""
    if len(pattern) > 1 and pattern.startswith("/") and pattern.endswith("/"):
        compiled = re.compile(pattern[1:-1])
        return compiled.search
    return lambda rel: fnmatch.fnmatch(rel, pattern)


def renovate_coverage(root: Path, config: str, exclude: list[str]) -> set[tuple[str, int]]:
    """Anchor positions a Renovate config's customManagers can actually reach.

    Its own `matchStrings` contain the anchor text verbatim, so the config file
    has to be excluded from the scan or it matches itself and reports a dozen
    anchors that do not exist.
    """
    cfg = load_json5(root / config)
    managers = cfg.get("customManagers", [])
    if not managers:
        raise CleaError(
            f"{config} declares no customManagers — either the inventory is wrong "
            "or this repository does not use Renovate; say so in clea.toml"
        )
    covered: set[tuple[str, int]] = set()
    for manager in managers:
        # Renovate renamed fileMatch to managerFilePatterns, and the two are not
        # spelled the same: fileMatch was always a regex, while a
        # managerFilePatterns entry is a regex only when it is delimited by
        # slashes and a glob otherwise. Reading a glob as a regex matches almost
        # nothing and would report every anchor as unwatched.
        modern = manager.get("managerFilePatterns")
        matchers = ([_file_matcher(p) for p in modern] if modern
                    else [_file_matcher("/%s/" % p) for p in manager.get("fileMatch", [])])
        for rel, full in _walk(root, [], exclude + [config]):
            if not any(match(rel) for match in matchers):
                continue
            try:
                text = full.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for match_string in manager.get("matchStrings", []):
                # Renovate uses JavaScript named groups; Python spells them (?P<…>).
                pattern = match_string.replace("(?<", "(?P<")
                try:
                    rx = re.compile(pattern, re.MULTILINE)
                except re.error as exc:
                    raise CleaError(f"{config}: unusable matchString {match_string!r}: {exc}")
                for m in rx.finditer(text):
                    covered.add((rel, text[: m.start()].count("\n") + 1))
    return covered


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

_NUM = re.compile(r"\d+")


def version_key(value: str) -> tuple:
    """Sortable key. Numeric segments compare as numbers, so 1.13.10 > 1.13.9.

    A string comparison gets that pair backwards, which is the one version bug
    every hand-rolled comparator ships with.
    """
    core, _, pre = value.lstrip("vV").partition("-")
    parts: list[int] = []
    for chunk in core.split("."):
        m = _NUM.match(chunk)
        parts.append(int(m.group(0)) if m else 0)
    # A release outranks any prerelease of the same number: (1,) beats (0, …).
    return (tuple(parts), (1,) if not pre else (0, pre))


def is_prerelease(value: str) -> bool:
    return bool(re.search(r"-(?:alpha|beta|rc|pre|dev|next)", value, re.I))


def is_newer(current: str, candidate: str) -> bool:
    return version_key(candidate) > version_key(current)


def same_shape(current: str, candidate: str) -> bool:
    """Both carry a leading v, or neither does.

    Writing `v1.2.3` where `1.2.3` was expected is how a pin becomes a download
    URL that 404s, and every consumer of that value reads it differently.
    """
    return current.startswith("v") == candidate.startswith("v")


def apply_extract(tag: str, extract_version: str | None) -> str:
    if not extract_version:
        return tag
    rx = re.compile(extract_version.replace("(?<", "(?P<"))
    m = rx.search(tag)
    if not m:
        return tag
    if "version" in rx.groupindex:
        return m.group("version")
    return m.group(1) if rx.groups else m.group(0)


# ---------------------------------------------------------------------------
# Datasources
# ---------------------------------------------------------------------------

def http_get(url: str, token: str | None = None, accept: str | None = None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if accept:
        request.add_header("Accept", accept)
    if token and urllib.parse.urlparse(url).hostname == "api.github.com":
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")[:400]
        except Exception:  # pragma: no cover - the status alone is enough
            pass
        if exc.code in (401, 403, 429):
            # Never let this read as "no new version". Unauthenticated GitHub
            # allows 60 requests an hour from an IP shared with every other
            # runner, and a silent 403 here is a report that says all is well.
            raise CleaError(
                f"{url} -> HTTP {exc.code}. Rate limited or unauthorised — export "
                f"GITHUB_TOKEN. Body: {body}"
            ) from exc
        raise CleaError(f"{url} -> HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CleaError(f"{url} -> {exc}") from exc


def _gh_json(path: str, token: str | None):
    raw = http_get(f"https://api.github.com{path}", token,
                   accept="application/vnd.github+json")
    return json.loads(raw)


def latest_github_releases(dep: str, token: str | None, **_) -> dict:
    data = _gh_json(f"/repos/{dep}/releases/latest", token)
    tag = data.get("tag_name")
    if not tag:
        raise CleaError(f"github-releases {dep}: no tag_name in the answer")
    return {
        "tag": tag,
        "released_at": data.get("published_at"),
        "notes_url": data.get("html_url"),
    }


def latest_github_tags(dep: str, token: str | None, **_) -> dict:
    data = _gh_json(f"/repos/{dep}/tags?per_page=100", token)
    tags = [t["name"] for t in data if not is_prerelease(t["name"])]
    if not tags:
        raise CleaError(f"github-tags {dep}: no usable tag")
    tag = max(tags, key=version_key)
    return {"tag": tag, "released_at": None,
            "notes_url": f"https://github.com/{dep}/releases/tag/{tag}"}


def latest_pypi(dep: str, _token: str | None, **_) -> dict:
    data = json.loads(http_get(f"https://pypi.org/pypi/{dep}/json"))
    version = data.get("info", {}).get("version")
    if not version:
        raise CleaError(f"pypi {dep}: no info.version")
    return {"tag": version, "released_at": None,
            "notes_url": f"https://pypi.org/project/{dep}/{version}/"}


def latest_helm(dep: str, _token: str | None, registry_url: str | None = None, **_) -> dict:
    """Newest chart version in a Helm repository index.

    Line-scanned rather than YAML-parsed: PyYAML is not in the standard library
    and this file refuses a dependency for one field.
    """
    if not registry_url:
        raise CleaError(f"helm {dep}: no registryUrl on the anchor")
    text = http_get(registry_url.rstrip("/") + "/index.yaml").decode("utf-8", "replace")
    versions: list[str] = []
    entry_indent: int | None = None
    inside = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if re.match(rf"^{re.escape(dep)}:\s*$", stripped) and not inside:
            inside, entry_indent = True, indent
            continue
        if inside:
            if indent <= entry_indent and not stripped.startswith("-"):
                break
            m = re.match(r"-?\s*version:\s*\"?([^\"\s]+)\"?$", stripped)
            if m:
                versions.append(m.group(1))
    versions = [v for v in versions if not is_prerelease(v)]
    if not versions:
        raise CleaError(f"helm {dep}: no version under entries in {registry_url}")
    tag = max(versions, key=version_key)
    return {"tag": tag, "released_at": None, "notes_url": registry_url}


def latest_terraform_provider(dep: str, _token: str | None,
                              registry_url: str | None = None, **_) -> dict:
    base = (registry_url or "https://registry.opentofu.org").rstrip("/")
    data = json.loads(http_get(f"{base}/v1/providers/{dep}/versions"))
    versions = [v["version"] for v in data.get("versions", [])
                if not is_prerelease(v["version"])]
    if not versions:
        raise CleaError(f"terraform-provider {dep}: no version at {base}")
    tag = max(versions, key=version_key)
    return {"tag": tag, "released_at": None,
            "notes_url": f"https://github.com/{dep.split('/')[0]}/terraform-provider-{dep.split('/')[-1]}/releases/tag/v{tag}"}


def latest_url_text(dep: str, _token: str | None, url: str | None = None,
                    extract: str | None = None, **_) -> dict:
    """A plain URL whose body is (or contains) the version.

    This is what covers a tool installed from a moving target — the kind of pin
    that is not a pin at all, like `dl.k8s.io/release/stable.txt`.
    """
    if not url:
        raise CleaError(f"url-text {dep}: no url")
    body = http_get(url).decode("utf-8", "replace").strip()
    if extract:
        m = re.search(extract.replace("(?<", "(?P<"), body, re.MULTILINE)
        if not m:
            raise CleaError(f"url-text {dep}: {extract!r} matched nothing at {url}")
        body = m.groupdict().get("v") or m.group(0)
    if not body:
        raise CleaError(f"url-text {dep}: {url} answered nothing")
    return {"tag": body.strip(), "released_at": None, "notes_url": url}


DATASOURCES = {
    "github-releases": latest_github_releases,
    "github-tags": latest_github_tags,
    "pypi": latest_pypi,
    "helm": latest_helm,
    "terraform-provider": latest_terraform_provider,
    "url-text": latest_url_text,
}


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "scan": {"marker": "# renovate:", "exclude": [], "include": []},
    "report": {"title": "Cléa — dependency report", "label": "clea"},
    "inventory": [],
    "tool": [],
    "unpinned": [],
    "lane": {},
}


def load_config(path: Path) -> dict:
    if not path.is_file():
        raise CleaError(f"no {path} — Cléa needs one, it is the only thing it knows")
    with path.open("rb") as handle:
        raw = tomllib.load(handle)
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    for key, value in raw.items():
        if isinstance(value, dict) and isinstance(cfg.get(key), dict):
            cfg[key].update(value)
        else:
            cfg[key] = value
    return cfg


def repo_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return Path(out.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd()


# ---------------------------------------------------------------------------
# coverage
# ---------------------------------------------------------------------------

def cmd_coverage(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, novalue = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])

    # Zero floor. "0 anchors, none unwatched" and "every anchor is watched" look
    # identical in a green run, and only one of them is true.
    if not anchors and not novalue:
        print(f"✗ no version anchor found under {root} — the scanner is broken, "
              "not the repository", file=sys.stderr)
        return 1

    seen: dict[str, set[tuple[str, int]]] = {}
    for inventory in cfg["inventory"]:
        kind = inventory.get("kind")
        if kind == "renovate":
            seen["renovate"] = renovate_coverage(
                root, inventory["config"], scan["exclude"] + inventory.get("exclude", []))
        else:
            raise CleaError(f"clea.toml: unknown inventory kind {kind!r}")

    failures = 0
    print(f"=== {len(anchors)} anchors read, {len(novalue)} carrying no version ===")

    for anchor in novalue:
        print(f"  ✗ {anchor.path}:{anchor.line} — {anchor.dep}: the anchor marks no "
              f"version ({anchor.reason}). Nothing can bump it, and it reads as if "
              "something could.")
        failures += 1

    for name, covered in seen.items():
        missing = [a for a in anchors if a.key not in covered]
        if missing:
            print(f"\n  {name} cannot see {len(missing)} of {len(anchors)}:")
            for anchor in missing:
                print(f"  ✗ {anchor.path}:{anchor.line} — {anchor.dep} = {anchor.value} "
                      f"({anchor.form})")
            failures += len(missing)
        else:
            print(f"  ✓ {name} sees all {len(anchors)}")

    print()
    if failures:
        print(f"{failures} unwatched pin(s). A pin nothing watches is a pin nobody bumps.")
        return 1
    print(f"{len(anchors)} anchors, every one watched.")
    return 0


# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

def _load_previous(path: str | None) -> dict:
    """Previous state, from a state file or from a report that embeds one."""
    if not path:
        return {}
    text = Path(path).read_text(encoding="utf-8")
    m = re.search(r"<!--\s*clea-state\s+(\{.*?\})\s*-->", text, re.DOTALL)
    if m:
        text = m.group(1)
    try:
        return json.loads(text)
    except ValueError:
        return {}


def cmd_scan(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    anchors, novalue = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    if not anchors:
        print("✗ no readable anchor — nothing to scan", file=sys.stderr)
        return 1
    if not token:
        print("⚠ no GITHUB_TOKEN: 60 requests an hour from a shared runner IP. "
              "This will rate-limit, loudly.", file=sys.stderr)

    previous = _load_previous(args.previous)
    prev_by_key = {d["dep"] + "@" + d["file"]: d for d in previous.get("deps", [])}

    # One upstream call per (datasource, dep), not per anchor: helm is pinned in
    # two files here and the API does not need asking twice.
    cache: dict[tuple[str, str], dict | str] = {}
    deps, errors = [], []

    def resolve(datasource: str, name: str, **kwargs) -> dict:
        key = (datasource, name)
        if key not in cache:
            fetch = DATASOURCES.get(datasource)
            if fetch is None:
                cache[key] = CleaError(f"unknown datasource {datasource!r} for {name}")
            else:
                try:
                    cache[key] = fetch(name, token, **kwargs)
                except CleaError as exc:
                    cache[key] = exc
        got = cache[key]
        if isinstance(got, CleaError):
            raise got
        return got

    for anchor in anchors:
        entry = {
            "dep": anchor.dep,
            "datasource": anchor.datasource,
            "file": anchor.path,
            "line": anchor.line,
            "form": anchor.form,
            "current": anchor.value,
            "pinned": True,
        }
        try:
            upstream = resolve(anchor.datasource, anchor.dep,
                               registry_url=anchor.attrs.get("registryUrl"))
            latest = apply_extract(upstream["tag"], anchor.attrs.get("extractVersion"))
            entry.update(latest=latest, released_at=upstream.get("released_at"),
                         notes_url=upstream.get("notes_url"),
                         behind=is_newer(anchor.value, latest),
                         shape_ok=same_shape(anchor.value, latest))
        except CleaError as exc:
            entry.update(latest=None, error=str(exc), behind=False)
            errors.append(str(exc))
        tool = next((t for t in cfg["tool"] if t["name"] == anchor.dep), None)
        if tool:
            entry["tool"] = tool
        was = prev_by_key.get(entry["dep"] + "@" + entry["file"], {})
        entry["moved_since_last_scan"] = bool(
            was.get("latest") and entry.get("latest") and was["latest"] != entry["latest"])
        deps.append(entry)

    for item in cfg["unpinned"]:
        entry = {"dep": item["name"], "datasource": item["datasource"],
                 "file": item.get("consumed_by", ""), "line": 0, "form": "unpinned",
                 "current": None, "pinned": False}
        try:
            upstream = resolve(item["datasource"], item["name"],
                               url=item.get("url"), extract=item.get("extract"),
                               registry_url=item.get("registry_url"))
            entry.update(latest=upstream["tag"], notes_url=upstream.get("notes_url"),
                         released_at=upstream.get("released_at"), behind=False)
        except CleaError as exc:
            entry.update(latest=None, error=str(exc), behind=False)
            errors.append(str(exc))
        was = prev_by_key.get(entry["dep"] + "@" + entry["file"], {})
        entry["moved_since_last_scan"] = bool(
            was.get("latest") and entry.get("latest") and was["latest"] != entry["latest"])
        deps.append(entry)

    state = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "deps": deps,
        "novalue": [{"dep": a.dep, "file": a.path, "line": a.line,
                     "reason": a.reason} for a in novalue],
        "unwatched": [],
        "errors": errors,
        "probes": previous.get("probes", []),
    }

    for inventory in cfg["inventory"]:
        if inventory.get("kind") != "renovate":
            continue
        try:
            covered = renovate_coverage(
                root, inventory["config"],
                scan["exclude"] + inventory.get("exclude", []))
            state["unwatched"] = [
                {"dep": a.dep, "file": a.path, "line": a.line,
                 "current": a.value, "inventory": "renovate"}
                for a in anchors if a.key not in covered]
        except CleaError as exc:
            errors.append(str(exc))

    Path(args.state).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    behind = [d for d in deps if d.get("behind")]
    print(f"{len(deps)} dependencies, {len(behind)} behind, "
          f"{len(state['unwatched'])} unwatched, {len(errors)} error(s)")

    # A datasource that answered nothing is not a dependency that is up to date.
    if errors and args.strict:
        for message in errors:
            print(f"  ✗ {message}", file=sys.stderr)
        return 1
    return 0


# ---------------------------------------------------------------------------
# config — one value, for the shell around Cléa
# ---------------------------------------------------------------------------

def cmd_config(args) -> int:
    """Print one dotted key from clea.toml, so a workflow reads the config
    rather than repeating it. A second copy of a value is a second thing to
    drift, and this repository already has the scars."""
    node = load_config(repo_root(args.root) / args.config)
    for part in args.key.split("."):
        if not isinstance(node, dict) or part not in node:
            raise CleaError(f"clea.toml has no {args.key}")
        node = node[part]
    print(node if not isinstance(node, (dict, list)) else json.dumps(node))
    return 0


# ---------------------------------------------------------------------------
# matrix — what the probe lanes should run
# ---------------------------------------------------------------------------

def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def cmd_matrix(args) -> int:
    """One entry per dependency to probe, as a GitHub Actions matrix.

    Keyed on the dependency, not on the anchor: a bump rewrites every site at
    once, so probing helm twice because it is pinned in two files would test the
    same tree twice.
    """
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    seen: dict[str, dict] = {}
    for dep in state.get("deps", []):
        if not (dep.get("behind") and dep.get("pinned")):
            continue
        if not dep.get("shape_ok", True):
            continue  # bumping it would write a value its consumers read differently
        tool = dep.get("tool") or {}
        if args.daily and tool and tool.get("daily") is False:
            continue
        if args.heavy_only and not (tool and tool.get("daily") is False):
            continue
        key = dep["dep"]
        if key in seen:
            continue
        seen[key] = {
            "dep": key,
            "version": dep["latest"],
            "slug": slugify(key),
            "installer": tool.get("installer", ""),
            "version_cmd": tool.get("version_cmd", ""),
            "installer_stdin": tool.get("installer_stdin", ""),
        }
    entries = sorted(seen.values(), key=lambda e: e["dep"])
    print(json.dumps(entries, separators=(",", ":")))
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _table(rows: list[list[str]], head: list[str]) -> str:
    out = ["| " + " | ".join(head) + " |",
           "|" + "|".join(["---"] * len(head)) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def render_report(state: dict) -> str:
    deps = state.get("deps", [])
    behind = [d for d in deps if d.get("behind")]
    unpinned = [d for d in deps if not d.get("pinned")]
    lines = [f"_Generated {state.get('generated_at', '?')} by "
             "[Cléa](../blob/main/scripts/clea/README.md). "
             "This issue is rewritten in place; do not open another._", ""]

    lines += ["## Behind upstream", ""]
    if behind:
        rows = []
        for d in behind:
            probe = next((p for p in state.get("probes", [])
                          if p["dep"] == d["dep"] and p["version"] == d["latest"]), None)
            verdict = "not probed"
            if probe:
                verdict = ("✅ probed green — `%s`" % probe["branch"]) if probe["green"] \
                    else "❌ probe failed"
            notes = f"[notes]({d['notes_url']})" if d.get("notes_url") else "—"
            shape = "" if d.get("shape_ok", True) else " ⚠️ prefix differs"
            rows.append([f"`{d['dep']}`", f"`{d['current']}`", f"`{d['latest']}`{shape}",
                         f"`{d['file']}:{d['line']}`", verdict, notes])
        lines += [_table(rows, ["dependency", "pinned", "upstream", "where",
                                "probe", "release"]), ""]
    else:
        lines += ["Nothing is behind. Every pin matches its upstream.", ""]

    unwatched = state.get("unwatched", [])
    novalue = state.get("novalue", [])
    lines += ["## Not watched", ""]
    if unwatched or novalue or unpinned:
        if unwatched:
            lines += ["**Anchored, but no inventory can see it** — the pin exists, "
                      "the bot that should propose the bump never reads it:", ""]
            lines += [f"- `{u['file']}:{u['line']}` — `{u['dep']}` = `{u['current']}`"
                      for u in unwatched] + [""]
        if novalue:
            lines += ["**Anchor marking no version** — it can never be bumped, and it "
                      "reads to a human as if it could:", ""]
            lines += [f"- `{n['file']}:{n['line']}` — `{n['dep']}`: {n.get('reason', '')}"
                      for n in novalue] + [""]
        if unpinned:
            rows = [[f"`{d['dep']}`", f"`{d.get('latest') or '?'}`",
                     f"`{d['file']}`" if d["file"] else "—",
                     "moved since last scan" if d.get("moved_since_last_scan") else ""]
                    for d in unpinned]
            lines += ["**Consumed at whatever upstream serves today** — no pin, so no "
                      "two machines are guaranteed the same tool:", "",
                      _table(rows, ["dependency", "upstream today", "consumed by",
                                    "note"]), ""]
    else:
        lines += ["Every pin is anchored, readable and watched.", ""]

    failed = [p for p in state.get("probes", []) if not p["green"]]
    if failed:
        lines += ["## Probe failures", ""]
        for probe in failed:
            lines += [f"### `{probe['dep']}` → `{probe['version']}`", "",
                      "```", probe.get("log", "(no log captured)").strip(), "```", ""]

    if state.get("errors"):
        lines += ["## Datasources that did not answer", "",
                  "Not the same thing as up to date:", ""]
        lines += [f"- {e}" for e in state["errors"]] + [""]

    lines += ["## What this did not test", "",
              "- **No real cloud, ever.** This lane carries no provider credential and "
              "must fail if it ever needs one. A deploy on Scaleway, OVH or Outscale is "
              "run by hand, by someone watching — see `CONTRIBUTING.md`.",
              "- A green probe means the tool installs from cold, upgrades over its "
              "previous version, and the repository's own checks still pass. It does not "
              "mean the new version behaves the same on a running cluster."]
    cluster = state.get("cluster_lane")
    if cluster:
        lines += [f"- Weekly local cluster lane: **{cluster.get('verdict', '?')}**, "
                  f"last run {cluster.get('at', '?')} on Talos "
                  f"`{cluster.get('talos', '?')}` / Kubernetes `{cluster.get('k8s', '?')}`."]
    else:
        lines += ["- The weekly local cluster lane has not reported yet."]

    lines += ["", "<!-- clea-state " + json.dumps(state, separators=(",", ":")) + " -->"]
    return "\n".join(lines) + "\n"


def cmd_report(args) -> int:
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    text = render_report(state)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


# ---------------------------------------------------------------------------
# bump
# ---------------------------------------------------------------------------

def cmd_bump(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, _ = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    targets = [a for a in anchors if a.dep == args.dep]
    if not targets:
        print(f"✗ no readable anchor for {args.dep}", file=sys.stderr)
        return 1

    # Every site, not the first: one tool, one version, everywhere it is claimed.
    # Leaving a second copy behind is the drift this repository has paid for four
    # times in a week.
    changed = 0
    for anchor in targets:
        new_value = apply_extract(args.version, anchor.attrs.get("extractVersion"))
        if not same_shape(anchor.value or "", new_value):
            print(f"✗ {anchor.path}:{anchor.value_line} — {anchor.value!r} and "
                  f"{new_value!r} do not carry the same v prefix; the consumers of "
                  "this value read them differently", file=sys.stderr)
            return 1
        if anchor.value == new_value:
            continue
        path = root / anchor.path
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        idx = (anchor.value_line or 1) - 1
        start, end = anchor.span or (0, 0)
        line = lines[idx]
        lines[idx] = line[:start] + new_value + line[end:]
        path.write_text("".join(lines), encoding="utf-8")
        print(f"  {anchor.path}:{anchor.value_line}  {anchor.value} -> {new_value}")
        changed += 1

    # A writer that writes nothing is the false-green this whole file exists
    # against: the probe would then test the version already in the tree and
    # report the bump as proven.
    if not changed:
        print(f"✗ {args.dep} is already at {args.version} everywhere — nothing to "
              "probe", file=sys.stderr)
        return 1
    print(f"{changed} site(s) rewritten")
    return 0


# ---------------------------------------------------------------------------
# prune
# ---------------------------------------------------------------------------

def cmd_prune(args) -> int:
    """Probe branches whose bump has already landed on the base branch.

    Compared on the PIN, not on the diff: a probe branch also carries its own
    verdict file, so it never becomes byte-identical to the base and a diff test
    would prune nothing, ever.
    """
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, _ = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    current: dict[str, str] = {}
    for anchor in anchors:
        # The lowest of a dependency's sites: while one file is still behind,
        # the bump has not fully landed and the branch is still worth keeping.
        if anchor.dep not in current or version_key(anchor.value or "") < version_key(current[anchor.dep]):
            current[anchor.dep] = anchor.value or ""

    refs = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname:short)",
         f"refs/remotes/origin/{args.prefix}*"],
        capture_output=True, text=True, check=False).stdout.split()
    for ref in refs:
        blob = subprocess.run(["git", "show", f"{ref}:clea-probe.json"],
                              capture_output=True, text=True, check=False)
        if blob.returncode != 0:
            continue  # not one of ours, or pushed before the verdict file existed
        try:
            probe = json.loads(blob.stdout)
        except ValueError:
            continue
        landed = current.get(probe.get("dep", ""))
        if landed and not is_newer(landed, probe.get("version", "")):
            print(ref.removeprefix("origin/"))
    return 0


# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="clea", description=__doc__.splitlines()[0])
    parser.add_argument("--root", help="repository root (default: git toplevel)")
    parser.add_argument("--config", default="clea.toml")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("coverage", help="offline: every pin readable and watched")

    p_scan = sub.add_parser("scan", help="online: resolve upstream versions")
    p_scan.add_argument("--state", default="clea-state.json")
    p_scan.add_argument("--previous", help="last state file, or a report embedding one")
    p_scan.add_argument("--strict", action="store_true",
                        help="exit 1 if any datasource failed to answer")

    p_config = sub.add_parser("config", help="print one dotted key from clea.toml")
    p_config.add_argument("key")

    p_matrix = sub.add_parser("matrix", help="GitHub Actions matrix of what to probe")
    p_matrix.add_argument("--state", default="clea-state.json")
    p_matrix.add_argument("--daily", action="store_true",
                          help="skip anything a tool row marked daily = false")
    p_matrix.add_argument("--heavy-only", action="store_true",
                          help="only what daily skips")

    p_report = sub.add_parser("report", help="render Markdown from a state file")
    p_report.add_argument("--state", default="clea-state.json")
    p_report.add_argument("--out")

    p_bump = sub.add_parser("bump", help="rewrite a pin in place")
    p_bump.add_argument("dep")
    p_bump.add_argument("version")

    p_prune = sub.add_parser("prune", help="name probe branches already landed")
    p_prune.add_argument("--base", default="main")
    p_prune.add_argument("--prefix", default="clea/probe/")

    args = parser.parse_args(argv)
    handlers = {"coverage": cmd_coverage, "scan": cmd_scan, "report": cmd_report,
                "bump": cmd_bump, "prune": cmd_prune, "matrix": cmd_matrix,
                "config": cmd_config}
    try:
        return handlers[args.command](args)
    except CleaError as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
