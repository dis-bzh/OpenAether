#!/usr/bin/env python3
"""Vérifie que le Cilium des clusters ENFANTS (CAPI) reste aligné sur le socle.

Pourquoi ce contrôle existe
---------------------------
Le socle parent configure Cilium via `helm template --set …` dans
`scripts/bootstrap/render-bootstrap-manifests.sh` ; les enfants CAPI le
configurent via le bloc `values:` d'un HelmRelease dans
`OpenAether-apps/apps/clusters/*.yaml`. Deux formats, deux dépôts, aucun lien
mécanique : la dérive est silencieuse et ne se voit qu'en production.

Elle a coûté cher le 2026-07-26 : les enfants avaient perdu `ipam.mode=kubernetes`.
Le défaut du chart (`cluster-pool`) ignore le `clusterNetwork.pods` déclaré par
CAPI et taille les CIDR de pods dans 10.0.0.0/8 — le /8 où vivent justement les
sous-réseaux de nœuds (10.20.0.0/24 côté OpenStack, 10.0.0.0/24 pour OVH,
Outscale et Proxmox). Le parent, lui, pose ce réglage explicitement, pour
exactement cette raison.

Ce que le contrôle fait
-----------------------
Il compare, clé par clé, un jeu restreint de réglages « structurants » entre le
bloc production du script de rendu et chaque HelmRelease `*-cilium` des enfants.
Les écarts VOULUS sont déclarés dans EXCEPTIONS avec leur justification : une
divergence non déclarée fait échouer le contrôle.

Usage : python3 scripts/ops/check-cilium-parity.py   (exit 1 si dérive)
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

INFRA = pathlib.Path(__file__).resolve().parents[2]
RENDER_SH = INFRA / "scripts" / "bootstrap" / "render-bootstrap-manifests.sh"
CLUSTERS = INFRA.parent / "OpenAether-apps" / "apps" / "clusters"

# Réglages dont un écart parent/enfant casse le datapath ou le mesh. Volontairement
# court : on ne compare PAS ce qui dépend légitimement du cluster (replicas,
# k8sServiceHost…), seulement ce qui doit être identique partout.
CHECKED = [
    "ipam.mode",
    "kubeProxyReplacement",
    "socketLB.enabled",
    "socketLB.hostNamespaceOnly",
    "cni.exclusive",
    "bpf.masquerade",
    "bpf.hostLegacyRouting",
    "encryption.enabled",
    "encryption.type",
    "nodeSelectorLabels",
    "cgroup.autoMount.enabled",
    "cgroup.hostRoot",
    "k8sServiceHost",
    "k8sServicePort",
]

# Écarts assumés : clé -> raison. Tout autre écart est une régression.
EXCEPTIONS: dict[str, str] = {}


def parse_parent() -> dict[str, str]:
    """Extrait les --set du bloc PRODUCTION (pas le bloc local) du script."""
    text = RENDER_SH.read_text()
    # Le bloc prod est celui qui suit le `else` du test LOCAL_MODE.
    marker = "# Production mode"
    if marker not in text:
        sys.exit(f"❌ bloc production introuvable dans {RENDER_SH}")
    prod = text.split(marker, 1)[1]
    values: dict[str, str] = {}
    for key, val in re.findall(r"--set\s+([\w.]+)=(\S+)", prod):
        values[key] = val.strip("\\").strip('"')
    return values


def flatten(node, prefix: str = "") -> dict[str, str]:
    out: dict[str, str] = {}
    if isinstance(node, dict):
        for key, val in node.items():
            out.update(flatten(val, f"{prefix}{key}."))
    else:
        out[prefix.rstrip(".")] = str(node).lower() if isinstance(node, bool) else str(node)
    return out


def parse_children() -> dict[str, dict[str, str]]:
    children: dict[str, dict[str, str]] = {}
    for path in sorted(CLUSTERS.glob("*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
                continue
            if doc.get("spec", {}).get("chart", {}).get("spec", {}).get("chart") != "cilium":
                continue
            children[path.name] = flatten(doc["spec"].get("values", {}))
    return children


def main() -> int:
    parent = parse_parent()
    children = parse_children()
    if not children:
        sys.exit(f"❌ aucun HelmRelease Cilium trouvé dans {CLUSTERS}")

    drift: list[str] = []
    for name, values in children.items():
        for key in CHECKED:
            want, got = parent.get(key), values.get(key)
            if want is None:
                continue  # le parent ne pose pas la clé : rien à imposer
            if got == want or key in EXCEPTIONS:
                continue
            if got is None:
                drift.append(
                    f"  {name} : `{key}` ABSENT — le socle pose {key}={want}. "
                    "Une clé absente prend le DÉFAUT DU CHART, qui diffère."
                )
            else:
                drift.append(f"  {name} : `{key}`={got} — le socle pose {want}.")

    if drift:
        print("❌ Cilium des enfants désaligné du socle :\n" + "\n".join(drift))
        print(
            "\nAligner apps/clusters/*.yaml sur le bloc production de\n"
            f"{RENDER_SH.relative_to(INFRA)}, ou déclarer l'écart dans EXCEPTIONS\n"
            "de ce script avec sa justification."
        )
        return 1

    print(
        f"OK — {len(children)} enfant(s) alignés sur le socle "
        f"({len(CHECKED)} réglages contrôlés)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
