#!/bin/bash
set -e
export PATH=$PATH:/home/vde/.pulumi/bin
export PULUMI_CONFIG_PASSPHRASE="openaether"
cd infrastructure
# Ensure we are logged in locally
pulumi login --local
pulumi up --stack dev --yes
