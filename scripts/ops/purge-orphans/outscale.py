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
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        return {'error': e.read().decode()[:200]}


# Counted so a clean account SAYS it is clean. This script is the last thing
# standing between a failed teardown and a bill, and it used to report that by
# printing nothing at all — which reads like a finding, not like an all-clear.
TOTAL = 0


def do(action, payload, label):
    global TOTAL
    TOTAL += 1
    if not APPLY:
        print("  [dry-run]", label); return
    r = call(action, payload)
    print(("  ⚠ " + label + " : " + str(r['error'])[:110]) if 'error' in r else "  ✓ " + label)


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
if TOTAL == 0:
    print("Nothing to purge — the account is clean.")
elif not APPLY:
    print(f"\n{TOTAL} resource(s) targeted. Re-run with --apply to delete them.")
else:
    print("\nOutscale purge complete")
