#!/usr/bin/env bash
# Offline schema validation of flux-bootstrap.yaml.tftpl — the manifest that
# tells Flux what to reconcile, and until now validated by nobody (#114).
# ci.yml's security job comment used to claim Trivy scanned it; `.tftpl`
# matches no Trivy detector, and every yamllint invocation (`task lint`, the
# pre-commit hook) is scoped to `*.yaml`/`*.yml`. A wrong key (`internal` for
# `interval`), a quoted boolean, a `60` where `60s` is required, or a
# `v1beta2` that no longer exists would all have reached a cluster.
#
# CRD schemas come from the VENDORED flux-install.yaml, not from upstream or
# from flux-schema's own built-in Flux catalog — either could target a
# different Flux release than the one this repository actually pins,
# reintroducing the drift check-version-drift.sh exists to kill. The template's
# other kind (ConfigMap) falls back to the built-in `default` catalog.
#
# Needs the flux CLI with the flux-schema plugin installed — both pinned in
# ci.yml's lint job and in scripts/setup.sh, same version in each (`flux
# plugin install schema@<version>` does its own checksum verification, per
# fluxcd/flux2 RFC 0013's "centralized catalog with checksum verification").
#
# Usage: check-flux-schema.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MANIFESTS_DIR="infrastructure/opentofu/cluster/bootstrap-manifests"
TEMPLATE="${MANIFESTS_DIR}/flux-bootstrap.yaml.tftpl"
VENDORED="${MANIFESTS_DIR}/flux-install.yaml"

command -v flux >/dev/null 2>&1 || {
  echo "✗ flux CLI not found — scripts/setup.sh installs it (task setup)," >&2
  echo "  or see .github/workflows/ci.yml's lint job for the pinned version" >&2
  exit 1
}
flux schema version >/dev/null 2>&1 || {
  echo "✗ the flux-schema plugin is not installed — flux plugin install schema@<version>" >&2
  echo "  (scripts/setup.sh installs the pinned one — task setup)" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixed dummy values for every ${...} the template declares — see
# cluster/main.tf's templatefile() call for the real ones (grep it if this
# list and that call ever disagree). None need to resolve to anything real:
# the point is that the RENDERED yaml is schema-valid, not that these values
# mean something.
sed \
  -e 's|\${namespace}|flux-system|g' \
  -e 's|\${git_repo_url}|https://example.invalid/openaether.git|g' \
  -e 's|\${git_ref}|refs/heads/main|g' \
  -e 's|\${cluster_role}|management|g' \
  -e 's|\${cluster_id}|openaether-check-flux-schema|g' \
  -e 's|\${backup_target_url}|s3://openaether-check@fr-par/|g' \
  -e 's|\${backup_s3_bucket}|openaether-check|g' \
  -e 's|\${backup_s3_endpoint}|s3.fr-par.example.invalid|g' \
  "$TEMPLATE" > "$tmp/rendered.yaml"

flux schema extract crd "$VENDORED" -d "$tmp/schemas" >/dev/null

flux schema validate "$tmp/rendered.yaml" \
  --schema-location "$tmp/schemas" --schema-location default --verbose

echo "OK — flux-bootstrap.yaml.tftpl renders to schema-valid manifests (CRDs from the vendored flux-install.yaml)."
