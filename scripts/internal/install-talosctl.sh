#!/usr/bin/env bash
# Install talosctl, pinned and checksum-verified.
#
# It was the last tool here installed by piping an unpinned upstream script
# (`curl talos.dev/install | bash`), in a repository that checksums helm, task,
# gitleaks, feint and tflint. Same shape as install-task.sh now.
#
# The version is NOT a new anchor: it is the cluster's own `talos_version`, read
# from talos-version.sh, so the CLI cannot drift from the fleet it talks to.
# talos.dev/install also 301s to www.talos.dev, which a restricted egress policy
# may refuse; the release asset is the same binary from github.com.
#
# Usage: install-talosctl.sh [bin-dir]     (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/../lib/common.sh"

TALOS_VERSION="$("$HERE/talos-version.sh")"   # e.g. v1.13.9

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

# `talosctl version --client` is the only form that answers without a cluster:
# bare `talosctl version` tries to reach a node and fails where none is configured.
if command -v talosctl >/dev/null 2>&1 &&
  talosctl version --client 2>/dev/null | grep -qE "(^|[^0-9.])${TALOS_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "talosctl ${TALOS_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="talosctl-linux-amd64" ;;
  Linux-aarch64 | Linux-arm64) asset="talosctl-linux-arm64" ;;
  Darwin-x86_64) asset="talosctl-darwin-amd64" ;;
  Darwin-arm64) asset="talosctl-darwin-arm64" ;;
  *) echo "✗ no published talosctl binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/sha256sum.txt" "$base/sha256sum.txt"
# --ignore-missing: the file covers all twelve published platforms, and without
# it the check fails on the eleven we did not download — which reads like a bad
# binary rather than a file we never asked for.
(cd "$tmp" && sha256sum -c sha256sum.txt --ignore-missing)

mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/$asset" "$BIN_DIR/talosctl"
echo "installed talosctl ${TALOS_VERSION} → $BIN_DIR/talosctl"
