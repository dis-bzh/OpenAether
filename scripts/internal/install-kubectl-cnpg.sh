#!/usr/bin/env bash
# Install the CloudNativePG kubectl plugin, pinned and checksum-verified.
#
# `docs/upgrade.md` tells the operator to switch a CNPG primary over before the
# node hosting it can be drained — a primary cannot be evicted, only switched.
# That instruction named `kubectl cnpg promote` while nothing installed it, so
# the documented step was a dead end on a fresh machine (found 2026-08-14, the
# same shape as every other defect that week).
#
# Version tracks the operator in OpenAether-apps (apps/base/cnpg/): keep the
# minor aligned when that moves.
#
# Usage: install-kubectl-cnpg.sh [bin-dir]   (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=cloudnative-pg/cloudnative-pg extractVersion=^v(?<version>.*)$
CNPG_VERSION="1.23.6"

BIN_DIR="${1:-}"
if [ -z "$BIN_DIR" ]; then
  if [ -w /usr/local/bin ] || command -v sudo >/dev/null 2>&1; then
    BIN_DIR=/usr/local/bin
  else
    BIN_DIR="$HOME/.local/bin"
  fi
fi
SUDO=""
[ -w "$BIN_DIR" ] || [ ! -d "$BIN_DIR" ] || SUDO="sudo"

if command -v kubectl-cnpg >/dev/null 2>&1 &&
  kubectl-cnpg version 2>/dev/null | grep -qF "${CNPG_VERSION}"; then
  echo "kubectl-cnpg ${CNPG_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="kubectl-cnpg_${CNPG_VERSION}_linux_x86_64.tar.gz" ;;
  Linux-aarch64 | Linux-arm64) asset="kubectl-cnpg_${CNPG_VERSION}_linux_arm64.tar.gz" ;;
  Darwin-x86_64) asset="kubectl-cnpg_${CNPG_VERSION}_darwin_x86_64.tar.gz" ;;
  Darwin-arm64) asset="kubectl-cnpg_${CNPG_VERSION}_darwin_arm64.tar.gz" ;;
  *) echo "✗ no published kubectl-cnpg for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/cnpg-${CNPG_VERSION}-checksums.txt"
# Grep the one line rather than --ignore-missing: a hard failure if OUR asset is
# not in the checksums file is the point.
(cd "$tmp" && grep " ${asset}\$" checksums.txt | sha256sum -c -)

tar xzf "$tmp/$asset" -C "$tmp" kubectl-cnpg
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/kubectl-cnpg" "$BIN_DIR/kubectl-cnpg"
echo "installed kubectl-cnpg ${CNPG_VERSION} → $BIN_DIR/kubectl-cnpg"
