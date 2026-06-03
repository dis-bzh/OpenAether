#!/usr/bin/env bash
# ==============================================================================
# resolve-s3-cred.sh <provider> <ak|sk>
# Prints the PRIMARY S3 credential for the given provider — thin CLI over
# s3_cred() in lib/common.sh. Used by the Taskfile (env: sh:) to set AWS_*
# before `tofu init` / `tofu apply`.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
s3_cred "${1:?usage: resolve-s3-cred.sh <provider> <ak|sk>}" primary "${2:?usage: resolve-s3-cred.sh <provider> <ak|sk>}"
