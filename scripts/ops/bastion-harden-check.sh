#!/usr/bin/env bash
# ==============================================================================
# bastion-harden-check.sh — Post-deploy hardening validation for OpenAether bastion
#
# Usage:
#   ./scripts/bastion-harden-check.sh <bastion_ip> <bastion_user> <ssh_key>
#
# Checks (in order):
#   1. SSH tunnel non-regression: 6443 + 50000 reachable via bastion
#   2. Root login rejected
#   3. sshd: PermitRootLogin no + PasswordAuthentication no
#   4. nftables egress DROP: nc to 1.1.1.1:80 must time out
#   5. nftables egress ALLOW: nc to cluster private on 6443 must pass (if node IP given)
#   6. ss -tlnp: only :22 listening externally
#   7. bastion-admins group exists and user is a member
# ==============================================================================

set -euo pipefail

BASTION_IP="${1:?Usage: $0 <bastion_ip> <bastion_user> <ssh_key> [node_private_ip]}"
BASTION_USER="${2:?}"
SSH_KEY="${3:?}"
NODE_IP="${4:-}"

SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH_CMD="ssh ${SSH_OPTS} ${BASTION_USER}@${BASTION_IP}"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; ((PASS++)); }
fail() { echo "  [FAIL] $*"; ((FAIL++)); }
info() { echo "  [INFO] $*"; }
sep()  { echo ""; echo "=== $* ==="; }

# --------------------------------------------------------------------------
sep "1. SSH connectivity"
# --------------------------------------------------------------------------
if ${SSH_CMD} echo "ssh-ok" 2>/dev/null | grep -q "ssh-ok"; then
  ok "SSH login as ${BASTION_USER}@${BASTION_IP}"
else
  fail "SSH login failed — aborting further checks"
  echo ""
  echo "RESULT: 0 passed, 1 failed — bastion unreachable"
  exit 1
fi

# --------------------------------------------------------------------------
sep "2. Root login rejected"
# --------------------------------------------------------------------------
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
     root@"${BASTION_IP}" echo "root-ok" 2>/dev/null | grep -q "root-ok"; then
  ok "Root login rejected (expected)"
else
  fail "Root login SUCCEEDED — PermitRootLogin not effective"
fi

# --------------------------------------------------------------------------
sep "3. sshd config"
# --------------------------------------------------------------------------
SSHD_CONF=$(${SSH_CMD} "sudo sshd -T 2>/dev/null || cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null")

if echo "${SSHD_CONF}" | grep -qi "permitrootlogin.*no"; then
  ok "PermitRootLogin no"
else
  fail "PermitRootLogin is NOT 'no'"
fi

if echo "${SSHD_CONF}" | grep -qi "passwordauthentication.*no"; then
  ok "PasswordAuthentication no"
else
  fail "PasswordAuthentication is NOT 'no'"
fi

if echo "${SSHD_CONF}" | grep -qi "allowgroups.*bastion-admins"; then
  ok "AllowGroups bastion-admins"
else
  fail "AllowGroups bastion-admins not found"
fi

if echo "${SSHD_CONF}" | grep -qi "allowtcpforwarding.*yes"; then
  ok "AllowTcpForwarding yes"
else
  fail "AllowTcpForwarding not 'yes'"
fi

# --------------------------------------------------------------------------
sep "4. nftables egress DROP (internet)"
# --------------------------------------------------------------------------
EGRESS_RESULT=$(${SSH_CMD} "nc -z -w 3 1.1.1.1 80 2>&1; echo exit:\$?" || true)
if echo "${EGRESS_RESULT}" | grep -q "exit:1\|timed out\|refused"; then
  ok "Egress to 1.1.1.1:80 blocked (nftables DROP working)"
else
  # 443 is allowed (apt); 80 to arbitrary hosts should be blocked in nftables OUTPUT
  # if the SG also restricts, this confirms the double-defence
  info "nc exit: ${EGRESS_RESULT} — verify nftables OUTPUT chain allows only apt repos"
  fail "Egress to 1.1.1.1:80 not blocked — check nftables OUTPUT chain"
fi

# --------------------------------------------------------------------------
sep "5. nftables egress ALLOW (cluster private)"
# --------------------------------------------------------------------------
if [ -n "${NODE_IP}" ]; then
  if ${SSH_CMD} "nc -z -w 5 ${NODE_IP} 6443 2>&1; echo exit:\$?" | grep -q "exit:0\|succeeded"; then
    ok "Egress to ${NODE_IP}:6443 allowed (cluster reachable)"
  else
    fail "Egress to ${NODE_IP}:6443 blocked — check nftables private_cidr + node is up"
  fi
else
  info "Skipping cluster egress test (no NODE_IP provided)"
fi

# --------------------------------------------------------------------------
sep "6. Only :22 listening externally"
# --------------------------------------------------------------------------
LISTENING=$(${SSH_CMD} "ss -tlnp 2>/dev/null | grep LISTEN || netstat -tlnp 2>/dev/null | grep LISTEN || true")
NON_SSH=$(echo "${LISTENING}" | grep -v ":22 " | grep -v "127.0.0.1:" | grep -v "::1:" | grep LISTEN || true)
if [ -z "${NON_SSH}" ]; then
  ok "Only :22 listening on external interfaces"
else
  fail "Unexpected listening ports: ${NON_SSH}"
fi

# --------------------------------------------------------------------------
sep "7. bastion-admins group + user membership"
# --------------------------------------------------------------------------
if ${SSH_CMD} "getent group bastion-admins" | grep -q "bastion-admins"; then
  ok "Group bastion-admins exists"
else
  fail "Group bastion-admins missing"
fi

if ${SSH_CMD} "groups ${BASTION_USER}" | grep -q "bastion-admins"; then
  ok "${BASTION_USER} is member of bastion-admins"
else
  fail "${BASTION_USER} is NOT member of bastion-admins"
fi

# --------------------------------------------------------------------------
sep "8. SSH-CA placeholder files present"
# --------------------------------------------------------------------------
if ${SSH_CMD} "test -f /etc/ssh/trusted_user_ca.pub && echo ok" | grep -q "ok"; then
  ok "/etc/ssh/trusted_user_ca.pub exists (SSH-CA ready)"
else
  fail "/etc/ssh/trusted_user_ca.pub missing"
fi

if ${SSH_CMD} "test -d /etc/ssh/auth_principals && echo ok" | grep -q "ok"; then
  ok "/etc/ssh/auth_principals/ exists (SSH-CA ready)"
else
  fail "/etc/ssh/auth_principals/ missing"
fi

# --------------------------------------------------------------------------
sep "SUMMARY"
# --------------------------------------------------------------------------
echo ""
echo "  PASSED: ${PASS}"
echo "  FAILED: ${FAIL}"
echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo "  Bastion hardening: ALL CHECKS PASSED"
  exit 0
else
  echo "  Bastion hardening: ${FAIL} CHECK(S) FAILED"
  exit 1
fi
