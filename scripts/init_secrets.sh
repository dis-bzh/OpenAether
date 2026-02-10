#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenAether — Platform Secrets Initialization
# Manages secrets in OpenBao for Keycloak + CNPG
# Uses 'kubectl exec' to run commands securely inside the pod
# ─────────────────────────────────────────────────────────────

NAMESPACE="security"
DB_NAMESPACE="databases"
POD_NAME=""
CONTAINER_NAME="openbao"

# Require VAULT_TOKEN from environment (no hardcoded tokens)
if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "❌ VAULT_TOKEN environment variable is not set."
    echo "   For dev mode: export VAULT_TOKEN=root"
    echo "   For prod: use the initial root token from 'bao operator init'"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 1. Helper Function: Execute bao command inside pod
# ─────────────────────────────────────────────────────────────
bao_exec() {
    kubectl exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER_NAME" -- env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" bao "$@"
}

# ─────────────────────────────────────────────────────────────
# 2. Find Healthy OpenBao Pod
# ─────────────────────────────────────────────────────────────
echo "⏳ Waiting for OpenBao..."
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=openbao --timeout=120s
POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app=openbao -o jsonpath="{.items[0].metadata.name}" | head -n 1)

if [ -z "$POD_NAME" ]; then
    echo "❌ No OpenBao pod found."
    exit 1
fi
echo "🎯 Using Pod: $POD_NAME"

# ─────────────────────────────────────────────────────────────
# 3. Health Check
# ─────────────────────────────────────────────────────────────
echo "🔍 Checking OpenBao health..."
if ! bao_exec status > /dev/null 2>&1; then
    echo "❌ OpenBao is not healthy or sealed."
    echo "   If sealed, exec into the pod and run: bao operator unseal"
    exit 1
fi
echo "✅ OpenBao is healthy."

# ─────────────────────────────────────────────────────────────
# 4. Enable KV v2 Engine (idempotent)
# ─────────────────────────────────────────────────────────────
if ! bao_exec secrets list | grep -q "^secret/"; then
    echo "🔧 Enabling KV v2 secrets engine..."
    bao_exec secrets enable -path=secret kv-v2
else
    echo "✅ KV v2 engine already enabled at secret/"
fi

# ─────────────────────────────────────────────────────────────
# 5. Generate & Write Keycloak DB Credentials (idempotent)
# ─────────────────────────────────────────────────────────────
if bao_exec kv get secret/keycloak/db > /dev/null 2>&1; then
    echo "✅ Keycloak DB secret already exists. Skipping generation."
    # Retrieve existing password for CNPG update later if needed
    DB_PASS=$(bao_exec kv get -field=password secret/keycloak/db)
else
    echo "🔐 Generating Keycloak DB credentials..."
    DB_PASS=$(openssl rand -base64 24)
    bao_exec kv put secret/keycloak/db \
        username="keycloak" \
        password="$DB_PASS"
    echo "✅ Keycloak DB credentials stored."
fi

# ─────────────────────────────────────────────────────────────
# 6. Generate & Write Keycloak Admin Credentials (idempotent)
# ─────────────────────────────────────────────────────────────
if bao_exec kv get secret/keycloak/admin > /dev/null 2>&1; then
    echo "✅ Keycloak admin secret already exists. Skipping generation."
else
    echo "🔐 Generating Keycloak admin credentials..."
    ADMIN_PASS=$(openssl rand -base64 24)
    bao_exec kv put secret/keycloak/admin \
        username="admin" \
        password="$ADMIN_PASS"
    echo "✅ Keycloak admin credentials stored."
    echo "   ⚠ Save the admin password securely — it won't be displayed again."
fi

# ─────────────────────────────────────────────────────────────
# 7. Update CNPG (PostgreSQL) User (optional)
# ─────────────────────────────────────────────────────────────
if kubectl get pods -n "$DB_NAMESPACE" -l cnpg.io/cluster=keycloak-db --no-headers 2>/dev/null | grep -q Running; then
    echo "🐘 Updating CNPG PostgreSQL user..."
    # We already have DB_PASS from step 5 (either generated or retrieved)
    kubectl -n "$DB_NAMESPACE" exec -it keycloak-db-1 -- psql -U postgres -c \
        "ALTER USER keycloak WITH PASSWORD '$DB_PASS';" 2>/dev/null || \
        echo "⚠ Could not update CNPG user — cluster may be initializing."
else
    echo "ℹ CNPG cluster not running yet. Skipping DB user update."
fi

echo ""
echo "🎉 Initialization Complete."
echo "   External Secrets should sync momentarily."
echo "   Verify: kubectl get externalsecrets -A"
