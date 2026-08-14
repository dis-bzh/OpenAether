#!/usr/bin/env python3
"""Purges ALL OVH project resources (servers, LBs, FIPs, routers, networks,
security groups) — whole-account, no name filtering. See README.md.
Usage: purge-orphans-ovh.py [--apply]   (dry-run by default)"""
import os, sys, json, urllib.request

APPLY = '--apply' in sys.argv
base = os.environ['OS_AUTH_URL'].rstrip('/')
url = base + ('/auth/tokens' if base.endswith('/v3') else '/v3/auth/tokens')
auth = {"auth": {"identity": {"methods": ["password"], "password": {"user": {
    "name": os.environ['OS_USERNAME'], "password": os.environ['OS_PASSWORD'],
    "domain": {"name": os.environ.get('OS_USER_DOMAIN_NAME', 'Default')}}}},
    "scope": {"project": {"id": os.environ['OS_PROJECT_ID']}}}}
req = urllib.request.Request(url, data=json.dumps(auth).encode(),
                             headers={'Content-Type': 'application/json'})
with urllib.request.urlopen(req, timeout=30) as r:
    TOK, CAT = r.headers['X-Subject-Token'], json.load(r)['token']['catalog']
REGION = os.environ['OS_REGION_NAME'].lower()
H = {'X-Auth-Token': TOK, 'Content-Type': 'application/json'}


def ep(t):
    return next(e['url'] for s in CAT if s['type'] == t for e in s['endpoints']
                if e['interface'] == 'public' and e['region'].lower() == REGION).rstrip('/')


def get(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=60))


# Counted so a clean project SAYS it is clean. This script is the last thing
# standing between a failed teardown and a bill, and it used to report that by
# printing nothing at all — which reads like a finding, not like an all-clear.
TOTAL = 0


def delete(u, label):
    global TOTAL
    TOTAL += 1
    if not APPLY:
        print("  [dry-run]", label)
        return
    try:
        urllib.request.urlopen(urllib.request.Request(u, headers=H, method='DELETE'), timeout=90)
        print("  ✓ deleted:", label)
    except Exception as e:
        print("  ⚠ failed:", label, str(e)[:80])


net, comp = ep('network'), ep('compute')
try:
    lb_ep = ep('load-balancer')
except StopIteration:
    lb_ep = None

# 1. servers (VMs block the deletion of ports/networks)
for s in get(comp + '/servers')['servers']:
    delete(comp + f"/servers/{s['id']}", f"server {s['name']}")

# 2. load balancers Octavia
if lb_ep:
    for lb in get(lb_ep + '/v2.0/lbaas/loadbalancers')['loadbalancers']:
        delete(lb_ep + f"/v2.0/lbaas/loadbalancers/{lb['id']}?cascade=true", f"LB {lb['name']}")

# 3. floating IPs
for f in get(net + '/v2.0/floatingips')['floatingips']:
    delete(net + f"/v2.0/floatingips/{f['id']}", f"FIP {f['floating_ip_address']}")

# 4. routers (detach the interfaces first)
for r in get(net + '/v2.0/routers')['routers']:
    for p in get(net + f"/v2.0/ports?device_id={r['id']}")['ports']:
        if p.get('device_owner', '').startswith('network:router_interface'):
            if APPLY:
                body = json.dumps({"port_id": p['id']}).encode()
                try:
                    urllib.request.urlopen(urllib.request.Request(
                        net + f"/v2.0/routers/{r['id']}/remove_router_interface",
                        data=body, headers=H, method='PUT'), timeout=60)
                    print("  ✓ interface detached:", p['id'][:8])
                except Exception as e:
                    print("  ⚠ detach:", str(e)[:60])
            else:
                print("  [dry-run] detach interface", p['id'][:8])
    delete(net + f"/v2.0/routers/{r['id']}", f"router {r['name']}")

# 5. networks + security groups
for n in get(net + '/v2.0/networks')['networks']:
    if n.get('project_id') == os.environ['OS_PROJECT_ID']:
        delete(net + f"/v2.0/networks/{n['id']}", f"network {n['name']}")
for g in get(net + '/v2.0/security-groups')['security_groups']:
    if g['name'] != 'default' and g.get('project_id') == os.environ['OS_PROJECT_ID']:
        delete(net + f"/v2.0/security-groups/{g['id']}", f"SG {g['name']}")

if TOTAL == 0:
    print("Nothing to purge — the project is clean.")
elif not APPLY:
    print(f"\n{TOTAL} resource(s) targeted. Re-run with --apply to delete them.")
    # Non-zero: see the note in scaleway.py. Callers read this exit code as
    # "the provider is clean", and it used to say yes regardless.
    sys.exit(1)
else:
    print("\npurge complete")
