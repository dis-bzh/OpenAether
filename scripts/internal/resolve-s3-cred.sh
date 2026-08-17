#!/usr/bin/env bash
# ==============================================================================
# resolve-s3-cred.sh <provider> <ak|sk> [primary|backup]
# Prints an S3 credential for the given provider — thin CLI over s3_cred() in
# lib/common.sh. Used by the Taskfile (env: sh:) to set AWS_* before
# `tofu init` / `tofu apply`.
#
# The kind defaults to `primary` for every existing caller. `backup` exists
# because the replica store may live on ANOTHER provider's account, which is
# exactly what this release asks for in production: reading it with the primary
# keys fails, and a checker that fails when the objective is MET gets muted and
# then protects nothing. s3_cred falls back to the primary keys when no backup
# ones are set, so a dev cluster whose replica shares its endpoint still works.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
s3_cred "${1:?usage: resolve-s3-cred.sh <provider> <ak|sk> [primary|backup]}" \
        "${3:-primary}" \
        "${2:?usage: resolve-s3-cred.sh <provider> <ak|sk> [primary|backup]}"
