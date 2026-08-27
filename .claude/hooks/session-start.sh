#!/bin/bash
# SessionStart hook — installs the OpenAether toolchain so `task lint`,
# `tofu fmt/validate/test` and `task test-scripts` work inside
# Claude Code on the web sessions.
#
# Requires the environment's network policy to allow outbound access to the
# tool download domains (get.opentofu.org, dl.k8s.io, github.com, pypi.org, ...).
# If egress is blocked, the installs below fail. The Docker lanes need one host
# beyond those: pkg-containers.githubusercontent.com, which serves ghcr.io's
# blobs — without it the daemon starts but `task local-up` cannot pull the Talos
# image.
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

# 3. Docker daemon. The remote image ships dockerd STOPPED — /var/run/docker.sock
# does not exist until something starts it — and every container lane here needs
# it: `task local-up`/`local-down`, test-talos-local.sh, test-gates-local.sh.
# Never fatal, and last on purpose: a session that cannot have Docker must still
# come out of this hook with the toolchain above.
start_dockerd() {
  if ! command -v dockerd > /dev/null 2>&1; then
    echo "⚠ dockerd is not installed — the Docker lanes (task local-*) are unavailable."
    return 0
  fi
  if docker info > /dev/null 2>&1; then
    echo "✅ Docker daemon already running."
    return 0
  fi
  $SUDO_CMD mkdir -p /var/log || true
  $SUDO_CMD sh -c 'dockerd >> /var/log/dockerd.log 2>&1 &' || true
  # It answers in about a second; 20 is headroom, not an expectation.
  for _ in $(seq 1 20); do
    if docker info > /dev/null 2>&1; then
      echo "✅ Docker daemon started."
      return 0
    fi
    sleep 1
  done
  echo "⚠ Docker daemon did not come up in 20s — see /var/log/dockerd.log."
}
start_dockerd
