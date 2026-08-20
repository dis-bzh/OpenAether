#!/usr/bin/env python3
"""Purges an orphaned Outscale Net (CAPI): dependencies first, then the Net.
Order imposed by Outscale: LBU → NAT → route tables → internet service →
security groups → subnets → net. Usage: purge-orphans-osc.py [--apply]"""
import os, sys, json, hmac, hashlib, datetime, urllib.request

APPLY = '--apply' in sys.argv
AK, SK = os.environ['OUTSCALE_ACCESS_KEY_ID'], os.environ['OUTSCALE_SECRET_KEY']
REGION, SERVICE = os.environ.get('OSC_REGION', 'eu-west-2'), 'api'
HOST = f"api.{REGION}.outscale.com"


def call(action, payload=None):
    body = json.dumps(payload or {})
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime('%Y%m%dT%H%M%SZ'), t.strftime('%Y%m%d')
    canonical = (f"POST\n/api/v1/{action}\n\ncontent-type:application/json\nhost:{HOST}\n"
                 f"x-amz-date:{amzdate}\n\ncontent-type;host;x-amz-date\n"
                 + hashlib.sha256(body.encode()).hexdigest())
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n" + hashlib.sha256(canonical.encode()).hexdigest()
    k = f"AWS4{SK}".encode()
    for part in (datestamp, REGION, SERVICE, 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"https://{HOST}/api/v1/{action}", data=body.encode(), method='POST',
        headers={'Content-Type': 'application/json', 'X-Amz-Date': amzdate,
                 'Authorization': f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                                  "SignedHeaders=content-type;host;x-amz-date, "
                                  f"Signature={sig}"})
    global UNREACHABLE
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        # COUNT it and SAY it. This returned {'error': …} in silence, every
        # listing then read as empty, and the script announced "the account is
        # clean" with exit 0 — measured with every call forced to HTTP 403, it
        # printed one line total. A refused question is not an empty answer, and
        # it must be louder than a network error, not quieter.
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {action} (HTTP {e.code})")
        return {'error': e.read().decode()[:200]}
    except Exception as e:                       # noqa: BLE001 — same reasoning
        UNREACHABLE += 1
        print(f"  ⚠ unreachable: {action} ({str(e)[:60]})")
        return {}


UNREACHABLE = 0


# Counted so a clean account SAYS it is clean. This script is the last thing
# standing between a failed teardown and a bill, and it used to report that by
# printing nothing at all — which reads like a finding, not like an all-clear.
TOTAL = 0


# Counted, not merely printed. A failed delete used to be one ⚠ line in a run
# that still ended "purge complete" with exit 0, so a caller reading the exit
# code heard "the account is clean" while everything was still there. Shown live
# on Outscale 2026-08-20: six resources found, six deletes refused, exit 0.
FAILED = 0


def do(action, payload, label):
    global TOTAL, FAILED
    TOTAL += 1
    if not APPLY:
        print("  [dry-run]", label); return
    r = call(action, payload)
    if 'error' in r:
        FAILED += 1
        print("  ⚠ " + label + " : " + str(r['error'])[:110])
    else:
        print("  ✓ " + label)


for lb in call('ReadLoadBalancers').get('LoadBalancers', []):
    do('DeleteLoadBalancer', {'LoadBalancerName': lb['LoadBalancerName']}, f"LBU {lb['LoadBalancerName']}")
for n in call('ReadNatServices').get('NatServices', []):
    if n.get('State') != 'deleted':
        do('DeleteNatService', {'NatServiceId': n['NatServiceId']}, f"NAT {n['NatServiceId']}")
for ip in call('ReadPublicIps').get('PublicIps', []):
    do('DeletePublicIp', {'PublicIpId': ip['PublicIpId']}, f"EIP {ip.get('PublicIp')}")
for rt in call('ReadRouteTables').get('RouteTables', []):
    for link in rt.get('LinkRouteTables') or []:
        do('UnlinkRouteTable', {'LinkRouteTableId': link['LinkRouteTableId']},
           f"unlink RT {rt['RouteTableId']}")
    do('DeleteRouteTable', {'RouteTableId': rt['RouteTableId']}, f"RT {rt['RouteTableId']}")
for igw in call('ReadInternetServices').get('InternetServices', []):
    if igw.get('NetId'):
        do('UnlinkInternetService', {'InternetServiceId': igw['InternetServiceId'],
                                     'NetId': igw['NetId']}, f"unlink IGW {igw['InternetServiceId']}")
    do('DeleteInternetService', {'InternetServiceId': igw['InternetServiceId']},
       f"IGW {igw['InternetServiceId']}")
for sg in call('ReadSecurityGroups').get('SecurityGroups', []):
    if sg.get('SecurityGroupName') != 'default' and sg.get('NetId'):
        do('DeleteSecurityGroup', {'SecurityGroupId': sg['SecurityGroupId']},
           f"SG {sg.get('SecurityGroupName')}")
for sn in call('ReadSubnets').get('Subnets', []):
    do('DeleteSubnet', {'SubnetId': sn['SubnetId']}, f"subnet {sn['SubnetId']}")
for net in call('ReadNets').get('Nets', []):
    do('DeleteNet', {'NetId': net['NetId']}, f"net {net['NetId']} ({net.get('IpRange')})")
if TOTAL == 0 and UNREACHABLE:
    print(f"\n✗ {UNREACHABLE} call(s) refused — found nothing, but nothing was actually asked.")
    print("  This is NOT an all-clear: check OUTSCALE_ACCESS_KEY_ID / _SECRET_KEY and re-run.")
    sys.exit(2)
if TOTAL == 0:
    print("Nothing to purge — the account is clean.")
elif not APPLY:
    print(f"\n{TOTAL} resource(s) targeted. Re-run with --apply to delete them.")
    # Non-zero: see the note in scaleway.py. Callers read this exit code as
    # "the provider is clean", and it used to say yes regardless.
    sys.exit(1)
elif FAILED:
    print(f"\n✗ {FAILED} of {TOTAL} deletion(s) failed — the account is NOT clean.")
    sys.exit(3)
else:
    print(f"\n{TOTAL} resource(s) deleted. The account is clean.")
