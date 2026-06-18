#!/bin/bash
# SessionStart hook — installs the OpenAether toolchain so `task lint`,
# `tofu fmt/validate/test` and `./scripts/dev/test-local-stack.sh` work inside
# Claude Code on the web sessions.
#
# Requires the environment's network policy to allow outbound access to the
# tool download domains (get.opentofu.org, talos.dev, dl.k8s.io, taskfile.dev,
# github.com, pypi.org, ...). If egress is blocked, the installs below fail.
set -euo pipefail

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
  curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh -o "$tmp"
  bash "$tmp"
fi

echo "✅ Toolchain ready (tofu, talosctl, kubectl, yamllint, tflint, task, flux)."
