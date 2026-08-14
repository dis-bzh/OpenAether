#!/bin/bash
# SessionStart hook — installs the OpenAether toolchain so `task lint`,
# `tofu fmt/validate/test` and `./scripts/dev/test-local-stack.sh` work inside
# Claude Code on the web sessions.
#
# Requires the environment's network policy to allow outbound access to the
# tool download domains (get.opentofu.org, talos.dev, dl.k8s.io, github.com,
# pypi.org, ...). If egress is blocked, the installs below fail.
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

# 2. tflint — setup.sh installs it now, through the same pinned installer CI
# uses. This copy was the third place the same download was written out by hand.

echo "✅ Toolchain ready (tofu, talosctl, kubectl, yamllint, tflint, task, flux)."
