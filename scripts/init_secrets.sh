#!/bin/bash
set -e

echo "Initializing Platform Secrets..."

# 1. Wait for OpenBao
echo "Waiting for OpenBao..."
kubectl -n security wait --for=condition=ready pod -l app=openbao --timeout=120s

# 2. Get/Set Vault Token (Dev Mode = root)
# In Prod, this would involve 'vault operator init' and unsealing.
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root" # Default in -dev mode

# Port Forwarding in background
kubectl -n security port-forward svc/openbao 8200:8200 > /dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID" EXIT
sleep 2

# 3. Enable KV v2 Engine (if not exists)
# In -dev mode, 'secret/' is usually mounted as v2 by default.
echo "Checking Vault status..."
curl --header "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/sys/health

# 4. Generate & Write Secrets
echo "Generating Keycloak DB Credentials..."
DB_PASS=$(openssl rand -base64 16)

# Write to OpenBao (KV v2 path: secret/data/...)
# Note: External Secrets expects data at 'secret/data/keycloak/db' if simple 'secret' mount is v2
curl \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data "{ \"data\": { \"username\": \"keycloak\", \"password\": \"$DB_PASS\" } }" \
    $VAULT_ADDR/v1/secret/data/keycloak/db

echo "✅ Secrets populated in OpenBao."
echo "   - Keycloak DB Password set."

# 5. Update CockroachDB User (Optional/Future Proofing)
# Since we are in insecure mode, CRDB accepts any password or none.
# But good practice to set it if we switch to secure later.
echo "Updating CockroachDB User..."
kubectl -n databases exec -it cockroachdb-0 -- ./cockroach sql --insecure --execute="ALTER USER keycloak WITH PASSWORD '$DB_PASS';" || echo "Warning: Could not set DB password, CRDB might be initializing."

echo "🎉 Initialization Complete. External Secrets should sync momentarily."
