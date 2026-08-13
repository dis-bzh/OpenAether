#!/bin/bash
# SessionStart hook — installs the OpenAether toolchain so `task lint`,
# `tofu fmt/validate/test` and `./scripts/dev/test-local-stack.sh` work inside
# Claude Code on the web sessions.
#
# Requires the environment's network policy to allow outbound access to the
# tool download domains (get.opentofu.org, talos.dev, dl.k8s.io, taskfile.dev,
# github.com, pypi.org, ...). If egress is blocked, the installs below fail.
set -euo pipefail

# root in the remote environment, sudo elsewhere.
if [ "$(id -u)" -eq 0 ]; then SUDO_CMD=""; else SUDO_CMD="sudo"; fi

# Only run in the remote (web) environment; locally you manage your own tools.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# 1. Core toolchain (tofu, talosctl, kubectl, yamllint, task, flux, image/backup
#    tools, pre-commit). The repo's own installer is idempotent and skips tools
#    that are already present. Feed 'y' so the pre-commit prompt is answered
#    non-interactively.
printf 'y\n' | ./scripts/setup.sh

# 2. tflint — used by `task lint` but not covered by setup.sh. Idempotent.
if ! command -v tflint >/dev/null 2>&1; then
  echo "Installing tflint..."
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  # Pinned + checksum-verified, like every other download in this repository.
  # This used to fetch install_linux.sh from `master` and run it: a moving remote
  # script, executed at session start, in the environment that holds the
  # credentials. CI pins the action by SHA; the tool it installs was `latest`.
  # renovate: datasource=github-releases depName=terraform-linters/tflint
  TFLINT_VERSION="v0.64.0"
  base="https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}"
  d="$(mktemp -d)"
  curl -fsSL -o "$d/tflint_linux_amd64.zip" "$base/tflint_linux_amd64.zip"
  curl -fsSL -o "$d/checksums.txt"          "$base/checksums.txt"
  ( cd "$d" && grep ' tflint_linux_amd64.zip$' checksums.txt | sha256sum -c - )
  unzip -q -o "$d/tflint_linux_amd64.zip" -d "$d"
  $SUDO_CMD install -m 0755 "$d/tflint" /usr/local/bin/tflint
  rm -rf "$d"
fi

echo "✅ Toolchain ready (tofu, talosctl, kubectl, yamllint, tflint, task, flux)."
