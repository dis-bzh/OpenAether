#!/usr/bin/env bash
# Install actionlint, pinned and checksum-verified.
#
# yamllint says a workflow file is well-formed YAML. It cannot say that
# `needs.scan.outputs.matrix` names an output that exists, that a `${{ }}` is
# valid where it sits, or that a `run:` block's shell is sound. Nothing here
# could, and a scheduled workflow cannot be dry-run: its first execution is
# production. actionlint answers all three statically, and runs shellcheck over
# every `run:` block on the way.
#
# Same shape as the other installers here: a pinned version, the project's own
# checksums file, and no third party in the path.
#
# Usage: install-actionlint.sh [bin-dir]   (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=rhysd/actionlint extractVersion=^v(?<version>.*)$
ACTIONLINT_VERSION="1.7.12"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

# Bounded, so 1.7.7 does not match 1.7.70.
if command -v actionlint >/dev/null 2>&1 &&
  actionlint --version 2>/dev/null |
    grep -qE "(^|[^0-9.])${ACTIONLINT_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "actionlint ${ACTIONLINT_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" ;;
  Linux-aarch64) asset="actionlint_${ACTIONLINT_VERSION}_linux_arm64.tar.gz" ;;
  Darwin-x86_64) asset="actionlint_${ACTIONLINT_VERSION}_darwin_amd64.tar.gz" ;;
  Darwin-arm64) asset="actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz" ;;
  *) echo "✗ no published actionlint binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "${base}/${asset}"
curl -fsSL -o "$tmp/checksums.txt" "${base}/actionlint_${ACTIONLINT_VERSION}_checksums.txt"
# --ignore-missing: the file lists every platform, and without it the check
# fails on the ones we did not download — which reads like a bad binary.
(cd "$tmp" && sha256sum -c checksums.txt --ignore-missing)
tar -xzf "$tmp/$asset" -C "$tmp" actionlint
mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/actionlint" "$BIN_DIR/actionlint"
echo "actionlint ${ACTIONLINT_VERSION} installed to ${BIN_DIR}"
