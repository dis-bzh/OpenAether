#!/usr/bin/env python3
"""Purges the Scaleway resources left behind by an orphaned cluster.
Targets the WHOLE project, like the ovh/outscale scripts.
Usage: scaleway.py [--apply]   (dry-run by default)

Block volumes are the reason this exists: a terminated VM can leave its root
volume behind, and those bill silently. Checking servers/LB/IPs alone made the
account look clean while 7 volumes had been billing for three days (2026-07-28).

Snapshots and images are deliberately NOT touched — they are the Talos image
artifacts, kept between sessions on purpose.
"""
import json
import os
import sys
import urllib.request

APPLY = '--apply' in sys.argv
TOKEN = os.environ['SCW_SECRET_KEY']
PROJECT = os.environ['SCW_DEFAULT_PROJECT_ID']
REGION = os.environ.get('SCW_DEFAULT_REGION', 'fr-par')
ZONES = os.environ.get('SCW_ZONES', f'{REGION}-1,{REGION}-2,{REGION}-3').split(',')
H = {'X-Auth-Token': TOKEN, 'Content-Type': 'application/json'}
API = 'https://api.scaleway.com'


def call(url, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=H, method=method)
    with urllib.request.urlopen(req, timeout=90) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


# Counted, not just printed. An endpoint that REFUSED to answer is not an
# endpoint that answered "nothing here" — but both used to leave `total` at 0,
# and the script then said "the project is clean" and exited 0. Measured: with
# every call forced to HTTP 403, this printed thirteen warnings and an all-clear.
# This script is the last sentence between a failed teardown and a bill.
UNREACHABLE = 0


def listing(url, key):
    global UNREACHABLE
    try:
        return call(url).get(key, [])
    except urllib.error.HTTPError as e:
        if e.code in (404, 501):                # service not offered in this zone
            return []
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {url.split('?')[0]} (HTTP {e.code})")
        return []
    except Exception as e:
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {url.split('?')[0]} ({str(e)[:60]})")
        return []


# Counted, not merely printed. A failed delete used to be one ⚠ line in a run
# that still ended "purge complete" with exit 0, so a caller reading the exit
# code heard "the account is clean" while everything was still there. Shown live
# on Outscale 2026-08-20: six resources found, six deletes refused, exit 0.
FAILED = 0


def act(label, fn):
    global FAILED
    if not APPLY:
        print("  [dry-run]", label)
        return
    try:
        fn()
        print("  ✓ deleted:", label)
    except Exception as e:
        FAILED += 1
        print("  ⚠ failed:", label, str(e)[:80])


total = 0
for z in ZONES:
    # 1. servers — `terminate` also releases the attached volumes and IPs.
    for s in listing(f'{API}/instance/v1/zones/{z}/servers?project={PROJECT}', 'servers'):
        total += 1
        act(f"[{z}] server {s['name']}",
            lambda i=s['id']: call(f'{API}/instance/v1/zones/{z}/servers/{i}/action',
                                   'POST', {'action': 'terminate'}))

    # 2. load balancers — release_ip so the flexible IP does not survive.
    for lb in listing(f'{API}/lb/v1/zones/{z}/lbs?project_id={PROJECT}', 'lbs'):
        total += 1
        act(f"[{z}] LB {lb['name']}",
            lambda i=lb['id']: call(f'{API}/lb/v1/zones/{z}/lbs/{i}?release_ip=true', 'DELETE'))

    # 3. flexible IPs left unattached.
    for ip in listing(f'{API}/instance/v1/zones/{z}/ips?project={PROJECT}', 'ips'):
        if ip.get('server'):
            continue
        total += 1
        act(f"[{z}] IP {ip['address']}",
            lambda i=ip['id']: call(f'{API}/instance/v1/zones/{z}/ips/{i}', 'DELETE'))

    # 4. block volumes — the leak this script was written for. `references`
    #    is empty once nothing is attached; a volume in use is left alone.
    for v in listing(f'{API}/block/v1alpha1/zones/{z}/volumes?project_id={PROJECT}', 'volumes'):
        if v.get('references'):
            continue
        total += 1
        act(f"[{z}] volume {v['name']} ({v['size'] // 10**9}GB)",
            lambda i=v['id']: call(f'{API}/block/v1alpha1/zones/{z}/volumes/{i}', 'DELETE'))

# 5. private networks — regional, and only removable once the NICs are gone.
for pn in listing(f'{API}/vpc/v2/regions/{REGION}/private-networks?project_id={PROJECT}',
                  'private_networks'):
    total += 1
    act(f"private network {pn['name']}",
        lambda i=pn['id']: call(f'{API}/vpc/v2/regions/{REGION}/private-networks/{i}', 'DELETE'))

if total == 0 and UNREACHABLE:
    print(f"\n✗ {UNREACHABLE} endpoint(s) refused to answer — found nothing, but nothing was")
    print("  actually asked. This is NOT an all-clear: check the credentials and re-run.")
    sys.exit(2)
if total == 0:
    print("Nothing to purge — the project is clean.")
elif not APPLY:
    print(f"\n{total} resource(s) targeted. Re-run with --apply to delete them.")
    # Exit NON-ZERO. This printed its findings and exited 0, so every caller
    # reading the exit code — a driver script on 2026-08-14, and a CI step that
    # called this "Confirm the provider is clean" — got a clean verdict while ten Scaleway
    # resources were billing. A check that cannot fail is not a check.
    sys.exit(1)
elif FAILED:
    print(f"\n✗ {FAILED} of {total} deletion(s) failed — the project is NOT clean.")
    sys.exit(3)
else:
    print(f"\n{total} resource(s) deleted. The project is clean.")
