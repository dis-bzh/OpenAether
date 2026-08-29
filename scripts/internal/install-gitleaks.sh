#!/usr/bin/env bash
# Install gitleaks, pinned and checksum-verified.
#
# `.pre-commit-config.yaml` names gitleaks as a `language: golang` hook, which
# pre-commit builds from source on first use. In this project's sandbox that
# build panics inside `wasilibs/go-re2`'s WASM regex engine (`invalid table
# access`, in wazero) — reproduced 6+ times across a full go-build-cache wipe,
# two Go toolchains (1.24.7 and 1.25.1) and GOMAXPROCS=1. The exact same
# version as an official RELEASE binary runs clean against the same tree
# (`no leaks found`) — the defect is in compiling gitleaks' WASM path from
# source here, not in gitleaks itself or in anything it scans. See #126.
#
# One way now, the same shape as every other tool here: a pinned version, the
# project's own checksums file, and no third party in the path. The
# `.pre-commit-config.yaml` gitleaks hook becomes a `language: system` hook
# that shells out to this binary instead of building one.
#
# Usage: install-gitleaks.sh [bin-dir]        (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v(?<version>.*)$
GITLEAKS_VERSION="8.22.1"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

if command -v gitleaks >/dev/null 2>&1 &&
  gitleaks version 2>/dev/null | grep -qE "(^|[^0-9.])${GITLEAKS_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "gitleaks v${GITLEAKS_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" ;;
  Linux-aarch64 | Linux-arm64) asset="gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz" ;;
  Darwin-x86_64) asset="gitleaks_${GITLEAKS_VERSION}_darwin_x64.tar.gz" ;;
  Darwin-arm64) asset="gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz" ;;
  *) echo "✗ no published gitleaks binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
# --ignore-missing: the file lists every platform, and without it the check fails
# on the ones we did not download — which reads like a bad binary.
(cd "$tmp" && sha256sum -c checksums.txt --ignore-missing)

tar xzf "$tmp/$asset" -C "$tmp" gitleaks
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/gitleaks" "$BIN_DIR/gitleaks"
echo "installed gitleaks v${GITLEAKS_VERSION} → $BIN_DIR/gitleaks"
