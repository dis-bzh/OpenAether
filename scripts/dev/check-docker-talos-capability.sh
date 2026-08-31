#!/usr/bin/env bash
# Preflight: can THIS host actually run Talos-in-Docker, or would it silently
# hang and then fail?
#
# Talos's in-node containerd sets its own OOM score to -999, which needs
# CAP_SYS_RESOURCE. Sandboxes and some CI runners drop that capability from the
# bounding set, and --privileged cannot get it back: Docker grants capabilities
# from its parent's bounding set, so a privileged container inherits the same
# hole. Without it the containers come up and look healthy while
# talos_machine_bootstrap (or test-talos-local.sh's own etcd-quorum poll) burns
# its full retry budget before failing on something unrelated-looking — see
# infrastructure/opentofu-local/README.md, "Host requirement: CAP_SYS_RESOURCE".
#
# No-op when capsh is absent (this check cannot tell, so it must not block a
# working setup) and non-fatal on anything but a confirmed-missing capability:
# same fail-open shape as check-host-ports.sh.
#
# Usage: check-docker-talos-capability.sh
set -uo pipefail

command -v capsh >/dev/null 2>&1 || exit 0

# The BOUNDING line, and only it: capsh names the capability twice more as a
# NEGATION ("cap_sys_resource-ep", "!cap_sys_resource"), so a bare grep over the
# whole output would report a missing capability as present.
BOUNDING="$(capsh --print 2>/dev/null | grep '^Bounding set')"
[ -n "$BOUNDING" ] || exit 0
echo "$BOUNDING" | grep -q cap_sys_resource && exit 0

cat >&2 <<'EOT'
✗ this host cannot run the Docker Talos lane — CAP_SYS_RESOURCE is missing
  from the container bounding set.

  Talos's containerd needs it to set its own OOM score; without it every node
  comes up and looks healthy while the cluster never actually bootstraps, and
  the failure only shows up ~90s later as an unrelated-looking timeout. There
  is no workaround on such a host — see infrastructure/opentofu-local/README.md,
  "Host requirement: CAP_SYS_RESOURCE".
EOT
exit 1
