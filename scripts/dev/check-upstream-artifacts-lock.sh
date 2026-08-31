#!/usr/bin/env bash
# cilium.yaml pins its three image refs by digest; flux-install.yaml pins
# seven controller images by tag only. A tag force-moved upstream changes not
# one byte of the committed YAML, so `task render-check` sees nothing, Cléa
# sees nothing (no `# renovate:` anchor on those lines), and Trivy has this
# file in `skip-files` (#119). This is the offline half of that gap: the
# committed artifacts must match the sha256 this repository already recorded
# for them — same idiom as install-talosctl.sh's checksum verification.
#
# Resolving the seven tags to ghcr digests (network) is the OTHER half, out of
# scope here — see #119.
#
# Usage: check-upstream-artifacts-lock.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFESTS_DIR="${ROOT}/infrastructure/opentofu/cluster/bootstrap-manifests"
LOCK="${MANIFESTS_DIR}/upstream-artifacts.lock"

[ -f "$LOCK" ] || {
  echo "✗ ${LOCK} is missing — scripts/bootstrap/render-bootstrap-manifests.sh" >&2
  echo "  (production mode, no flags) regenerates it after rendering cilium.yaml." >&2
  exit 1
}

cd "$MANIFESTS_DIR"
if ! sha256sum -c "$(basename "$LOCK")"; then
  cat >&2 <<'EOT'

✗ cilium.yaml / flux-install.yaml no longer match upstream-artifacts.lock.
  Either the artifact drifted from what was last rendered (regenerate it:
  ./scripts/bootstrap/render-bootstrap-manifests.sh, production mode, no
  flags — it rewrites the lock too), or the lock itself was hand-edited and
  no longer reflects a real render. Do not hand-edit the lock.
EOT
  exit 1
fi
echo "OK — cilium.yaml and flux-install.yaml match upstream-artifacts.lock."
