#!/usr/bin/env bash
# ==============================================================================
# resolve-s3-cred.sh <provider> <ak|sk> [primary|backup] [replica-endpoint]
# Prints an S3 credential for the given provider — thin CLI over s3_cred() in
# lib/common.sh. Used by the Taskfile (env: sh:) to set AWS_* before
# `tofu init` / `tofu apply`.
#
# The kind defaults to `primary` for every Taskfile caller. For `backup`, PASS
# THE REPLICA ENDPOINT: the store is opened with the keys of the cloud that
# holds it, and without the endpoint s3_cred can only fall back to this
# cluster's own — which is right for a single-provider setup and wrong for the
# cross-provider one this release exists to support.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
s3_cred "${1:?usage: resolve-s3-cred.sh <provider> <ak|sk> [primary|backup] [endpoint]}" \
        "${3:-primary}" \
        "${2:?usage: resolve-s3-cred.sh <provider> <ak|sk> [primary|backup] [endpoint]}" \
        "${4:-}"
