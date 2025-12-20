#!/bin/bash
export PATH=$PATH:/home/vde/.pulumi/bin
export PULUMI_CONFIG_PASSPHRASE="openaether"
pulumi up --stack dev --yes
