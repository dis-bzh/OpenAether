#!/usr/bin/env python3
"""Alloue (ou réutilise) la floating IP d'un control plane CAPO — idempotent.

Pourquoi ce script existe
-------------------------
Un enfant OpenStack a besoin de son IP flottante AVANT le boot : l'IMDS
OpenStack ne l'expose pas (NAT côté Neutron), donc elle doit figurer dans les
`certSANs` de la config Talos, donc dans le git. C'est la seule ressource d'un
enfant créée hors OpenTofu et hors CAPI — et donc la seule à re-créer à la main
après un teardown, en recopiant l'IP dans `apps/clusters/<enfant>.yaml`.

Ce script rend l'étape idempotente : il retrouve la FIP à sa description
(`openaether:<cluster>`), n'en alloue une que s'il n'y en a pas, et imprime
l'adresse. Le relancer ne crée jamais de doublon facturé.

Usage :
    source .env.sh
    python3 scripts/ops/ensure-capo-fip.py edge-2 [--network Ext-Net]

Puis reporter l'IP affichée dans `OS_CP_FLOATING_IPS` du fichier de l'enfant.
Une FIP par réplique de control plane : passer --count N.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

DESC_PREFIX = "openaether:"


def keystone_token() -> tuple[str, list]:
    base = os.environ["OS_AUTH_URL"].rstrip("/")
    url = base + ("/auth/tokens" if base.endswith("/v3") else "/v3/auth/tokens")
    auth = {
        "auth": {
            "identity": {
                "methods": ["password"],
                "password": {
                    "user": {
                        "name": os.environ["OS_USERNAME"],
                        "password": os.environ["OS_PASSWORD"],
                        "domain": {"name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")},
                    }
                },
            },
            "scope": {"project": {"id": os.environ["OS_PROJECT_ID"]}},
        }
    }
    req = urllib.request.Request(
        url, data=json.dumps(auth).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.headers["X-Subject-Token"], json.load(resp)["token"]["catalog"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cluster", help="nom du cluster enfant (ex: edge-2)")
    parser.add_argument("--network", default="Ext-Net", help="réseau externe (défaut: Ext-Net)")
    parser.add_argument("--count", type=int, default=1, help="nombre de FIP (1 par CP)")
    args = parser.parse_args()

    missing = [v for v in ("OS_AUTH_URL", "OS_USERNAME", "OS_PASSWORD", "OS_PROJECT_ID",
                           "OS_REGION_NAME") if not os.environ.get(v)]
    if missing:
        sys.exit(f"❌ variables OpenStack manquantes : {', '.join(missing)} (source .env.sh)")

    token, catalog = keystone_token()
    region = os.environ["OS_REGION_NAME"].lower()
    neutron = next(
        e["url"]
        for s in catalog
        if s["type"] == "network"
        for e in s["endpoints"]
        if e["interface"] == "public" and e["region"].lower() == region
    ).rstrip("/")
    headers = {"X-Auth-Token": token, "Content-Type": "application/json"}

    def get(path):
        req = urllib.request.Request(neutron + path, headers=headers)
        return json.load(urllib.request.urlopen(req, timeout=60))

    description = DESC_PREFIX + args.cluster
    existing = [
        f for f in get("/v2.0/floatingips")["floatingips"] if f.get("description") == description
    ]

    net = get(f"/v2.0/networks?name={args.network}")["networks"]
    if not net:
        sys.exit(f"❌ réseau externe '{args.network}' introuvable")
    net_id = net[0]["id"]

    while len(existing) < args.count:
        body = json.dumps(
            {"floatingip": {"floating_network_id": net_id, "description": description}}
        ).encode()
        req = urllib.request.Request(
            neutron + "/v2.0/floatingips", data=body, headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            fip = json.load(resp)["floatingip"]
        print(f"  + allouée : {fip['floating_ip_address']}", file=sys.stderr)
        existing.append(fip)

    if len(existing) > args.count:
        print(
            f"  ⚠ {len(existing)} FIP portent la description '{description}' pour "
            f"--count {args.count} — les surnuméraires sont facturées, à purger.",
            file=sys.stderr,
        )

    addresses = [f["floating_ip_address"] for f in existing[: args.count]]
    for f in existing[: args.count]:
        state = "associée" if f.get("port_id") else "libre"
        print(f"  ✓ {f['floating_ip_address']} ({state})", file=sys.stderr)
    print(
        f"\n→ reporter dans OS_CP_FLOATING_IPS de apps/clusters/{args.cluster}.yaml :",
        file=sys.stderr,
    )
    print(",".join(addresses))
    return 0


if __name__ == "__main__":
    sys.exit(main())
