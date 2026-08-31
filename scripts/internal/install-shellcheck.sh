#!/usr/bin/env bash
# Install shellcheck, pinned and checksum-verified.
#
# `task lint` gates on it, and ci.yml/setup.sh both used to
# `apt-get install -y shellcheck` with no version — "the GitHub runner image
# happens to ship it" is exactly the dependency this repository's OWN Task
# installer comment argues against, and setup.sh's apt fallback inherits
# whatever Ubuntu's archive currently carries. Same shape as
# install-tflint.sh/install-actionlint.sh, with one difference: ShellCheck's
# GitHub releases publish no checksums file, so the sha256 below is pinned
# INLINE, one per platform, computed once against the exact asset this version
# downloads. Recompute all four when bumping SHELLCHECK_VERSION — never trust
# an unverified download in their place (#113).
#
# Usage: install-shellcheck.sh [bin-dir]   (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=koalaman/shellcheck extractVersion=^v(?<version>.*)$
SHELLCHECK_VERSION="0.11.0"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

if command -v shellcheck >/dev/null 2>&1 &&
  shellcheck --version 2>/dev/null | grep -qE "(^|[^0-9.])${SHELLCHECK_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "shellcheck ${SHELLCHECK_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
    sha256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
    ;;
  Linux-aarch64 | Linux-arm64)
    asset="shellcheck-v${SHELLCHECK_VERSION}.linux.aarch64.tar.xz"
    sha256="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
    ;;
  Darwin-x86_64)
    asset="shellcheck-v${SHELLCHECK_VERSION}.darwin.x86_64.tar.xz"
    sha256="3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6"
    ;;
  Darwin-arm64)
    asset="shellcheck-v${SHELLCHECK_VERSION}.darwin.aarch64.tar.xz"
    sha256="56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79"
    ;;
  *) echo "✗ no published shellcheck binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
echo "${sha256}  $tmp/$asset" | sha256sum -c -

tar -xJf "$tmp/$asset" -C "$tmp" "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN_DIR/shellcheck"
echo "installed shellcheck ${SHELLCHECK_VERSION} → $BIN_DIR/shellcheck"
