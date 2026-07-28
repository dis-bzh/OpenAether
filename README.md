# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> Un cluster Talos idempotent sur n'importe quel environnement — local (Docker),
> on-prem (Proxmox) ou cloud (Scaleway/OVH/Outscale) — avec pour seul socle figé
> **CNI (Cilium) + Flux**. Tout le reste se pioche dans `OpenAether-apps`.

🇬🇧 [English version](README.en.md)

## Version

**v0.4.0+** — socle Talos modulaire multi-provider (cf. `CLAUDE.md` et
`CHANGELOG.md [Unreleased]`).

Management validé de bout en bout sur **Scaleway, OVH et Outscale** ; local
Docker validé (3 CP + 3 workers) ; Proxmox code-complet mais **jamais appliqué
sur matériel réel**. Backups tfstate/artefacts chiffrés côté client, double
store. Le multi-cloud actif-actif est abandonné ; le hub/spoke CAPI est une
**surcouche optionnelle**.

## Architecture

```
Un cluster Talos autonome (socle figé : Cilium + Flux)
  └── pioche modulaire dans OpenAether-apps (scripts/pick.py) :
      OpenBao, ESO, cert-manager/PKI, Istio ambient, gateway, CNPG,
      Longhorn, observabilité, Zitadel, Kyverno, backups restic…

Surcouche OPTIONNELLE — cluster de management (CAPI pioché) :
  Management (hub) ──CAPI+Talos──▶ clusters clients (kubeception)
                    ──Flux kubeConfig──▶ Cilium+Flux injectés à distance,
                    puis chaque enfant réconcilie SON profil git (gitception)
```

**Principe de conception** : le cluster de management n'est **pas** sur le
chemin de données des clients. S'il devient indisponible, les workloads
continuent de tourner — chaque enfant a son propre Flux.

## Deux façons d'amorcer le premier cluster

| Voie | Quand | Ce qu'elle crée |
|---|---|---|
| **OpenTofu** (défaut) | Tous les cas courants | Tout le substrat : réseau, routeur, security groups, LB, bastion, volumes, buckets S3 — puis Talos |
| **CAPI** (optionnel) | On veut un management décrit comme les autres clusters, et l'outillage day-2 de CAPI | Un cluster jetable crée le management, qui devient ensuite autogéré (`clusterctl move`) |

La voie CAPI **ne remplace pas** OpenTofu : sur OVH, OpenTofu crée ~44
ressources dont 3 seulement sont des instances. Procédure complète et pièges :
**[docs/capi-bootstrap.md](docs/capi-bootstrap.md)**.

## Statut des couches

| Couche | Technologie | Statut |
|--------|-------------|--------|
| **IaC** | OpenTofu 1.12.x | ✅ |
| **OS** | Talos Linux v1.13.x (immuable) | ✅ |
| **CNI** | Cilium 1.19.2 (WireGuard) | ✅ |
| **GitOps** | Flux v2.4.0 (hub/spoke) | ✅ |
| **Secrets** | OpenBao 2.5.4 (fork Vault) | ✅ validé en cloud réel |
| **PKI** | cert-manager v1.15.3 | ✅ |
| **Gateway / Mesh** | Istio 1.24.2 (ambient + Gateway API) | ✅ |
| **Base de données** | CloudNativePG 1.23.1 | ✅ |
| **Stockage** | Longhorn 1.9.2 | ✅ |
| **Identité** | Zitadel 10.0.2 | ✅ déployé — SSO Grafana à confirmer au navigateur |
| **Observabilité** | VictoriaMetrics operator 0.65.1, Loki 6.25.0, Grafana 8.6.4, Alloy 0.11.0 | ✅ |
| **Policy** | Kyverno v1.12.1 | ✅ |
| **Cluster API** | CAPI v1.13.2, CABPT v0.6.12, CACPPT v0.5.13, CAPS v0.2.1, CAPO v0.14.4, CAPOSC v1.5.0 | ✅ surcouche optionnelle |

## Providers

Même contrat pour tous (`modules/providers/provider-contract.md`) — le stack
Talos/cluster est provider-agnostique. Détail : `docs/deployment-test-matrix.md`.

| Provider | Statut | Région / cible | Notes |
|----------|--------|----------------|-------|
| **Scaleway** | ✅ management validé | fr-par (3 AZ) | Implémentation de référence ; rolling-replace exercé en réel |
| **OVH** | ✅ management validé | EU-WEST-PAR (OpenStack) | LB Octavia, floating IPs, routeur SNAT, réseau privé |
| **Outscale / Numspot** | ✅ management validé | eu-west-2 | LB, NAT-service, sous-réseaux public/privé, VPC |
| **Proxmox (on-prem)** | 🧪 code-complet, testé unitairement — **jamais appliqué en réel** | PVE mono/multi-hôte | VIP Talos (pas de LB managé), NAT/DNAT nftables, prérequis manuels |
| **Local (Docker)** | ✅ validé (`task local-up`) | WSL2 / Docker | 3 CP + 3 workers, quorum etcd, Cilium — preuve sans credentials de `modules/talos` |

## Structure du dépôt

```
OpenAether-infra/
├── infrastructure/
│   └── opentofu/
│       ├── cluster/                 # Racine cluster (management + workload)
│       │   ├── envs/                # Config par cluster (<rôle>-<provider>.tfvars)
│       │   ├── bootstrap-manifests/ # Cilium + Flux injectés au bootstrap
│       │   └── tests/               # Tests unitaires OpenTofu
│       ├── talos-image/             # Constructeur d'image (un state à part)
│       ├── opentofu-local/          # Racine locale Docker (réutilise modules/talos)
│       └── modules/
│           ├── talos/               # Secrets, config, bootstrap — provider-agnostique
│           ├── providers/           # provider-contract.md = le contrat
│           │   ├── scw/ ovh/ outscale/ proxmox/ local/
│           └── talos-image/         # Publication d'image par provider
└── scripts/
    ├── setup.sh
    ├── bootstrap/                   # Cycle de vie (rare)
    ├── ops/                         # Exploitation courante
    │   ├── fleet-down.sh            # Teardown ordonné (enfants puis management)
    │   ├── edge-down.sh             # Suppression d'un enfant CAPI (suspend Flux)
    │   ├── rolling-replace.sh       # Remplacement de nœud sans coupure
    │   ├── etcd-snapshot.sh         # Snapshot etcd chiffré → 2 stores
    │   ├── check-cilium-parity.py   # Garde-fou : enfants alignés sur le socle
    │   ├── preflight-quotas.py      # Vérifie les quotas AVANT de déployer
    │   ├── ensure-capo-fip.py       # FIP pré-allouée (certSANs OpenStack)
    │   └── purge-orphans/           # Filet de secours (API provider directe)
    └── internal/                    # Appelés par le Taskfile
```

Les manifests Kubernetes vivent dans
[dis-bzh/OpenAether-apps](https://github.com/dis-bzh/OpenAether-apps).

## Démarrage rapide

### Prérequis

```bash
./scripts/setup.sh          # tofu, talosctl, kubectl, task, helm, yamllint…

# Pour le CLOUD uniquement — le test local n'a besoin d'aucun credential.
cp .env.example .env.sh     # puis l'éditer
source .env.sh              # git-ignoré ; contient aussi TF_VAR_encryption_passphrase
```

⚠️ **Toujours `source .env.sh` avant un `task` qui touche au cloud.** Sans lui,
`tofu` réclame `var.encryption_passphrase` en interactif et la commande échoue —
y compris un teardown, qui peut alors sembler réussi sans rien détruire.

### Cluster local (Docker — sans cloud ni credentials)

Monte un vrai cluster Talos **3 control planes + 3 workers** dans Docker, sur le
**même `modules/talos/` qu'en production**. C'est le meilleur premier pas.

```bash
task local-up        # déploiement complet
task local-status    # membres etcd + nœuds + Flux
task local-down      # destruction (conteneurs + volumes + state)
```

⚠️ **Sous Windows/WSL2** : Hyper-V réserve des blocs de ports au-dessus de
49152, et ces blocs bougent au redémarrage. La base des ports hôte est donc
paramétrable (`talos_api_port_base`, défaut 41000). Diagnostiquer avec
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

### Cluster de management (cloud)

```bash
source .env.sh

cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
# Éditer : admin_ip, bastion_ssh_keys, image_name/image_id, s3_primary_*/s3_replica_*

task preflight-quotas PROVIDER=ovh          # vérifier les quotas d'abord
task talos-image PROVIDER=scaleway          # une fois par version d'image
task infra ROLE=management PROVIDER=scaleway
task bootstrap-phase2 ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

**Après le déploiement** : suivre le parcours jour-1
([docs/admin-access.md](docs/admin-access.md)) — escrow Shamir/root/restic,
signature offline de l'intermediate PKI, seed des destinations de backup, accès
admin aux UIs, secrets CAPI des enfants.

### Teardown

L'ordre compte : le management détient les CR de ses enfants.

```bash
source .env.sh
task edge-down CLUSTER=edge-1 -- --yes      # chaque enfant CAPI d'abord
task fleet-down PROVIDER=ovh -- --yes       # puis le management
python3 scripts/ops/purge-orphans/ovh.py    # dry-run : vérifier qu'il ne reste rien
```

⚠️ Les floating IPs pré-allouées hors OpenTofu ne partent pas seules, et un
cluster **autogéré** ne peut pas terminer sa propre suppression
(cf. `docs/capi-bootstrap.md`).

### Contrôles statiques (sans cloud ni Docker)

```bash
task validate            # tofu fmt/validate/test
task apps-validate       # intégrité du DAG Flux + profils pick.py à jour
task security            # contrôles de durcissement
```

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/admin-access.md](docs/admin-access.md) | Parcours jour-1 : escrow, PKI offline, accès UIs, tests navigateur |
| [docs/capi-bootstrap.md](docs/capi-bootstrap.md) | Amorcer un management par CAPI et le rendre autogéré |
| [docs/deployment-test-matrix.md](docs/deployment-test-matrix.md) | Ce qui est validé, où, et comment |
| [docs/backlog.md](docs/backlog.md) | **Source de vérité** : état courant, dette, améliorations |

## Sécurité

| Contrôle | Mise en œuvre |
|----------|---------------|
| Aucune IP publique sur les nœuds | VPC seul, tunnel SSH via bastion |
| SSH bastion | Utilisateur dédié non privilégié, clé uniquement (root et mots de passe désactivés) |
| Chiffrement du state | AES-GCM + PBKDF2 côté client (`encryption{}`) avant S3 |
| Chiffrement des artefacts | gpg AES-256 authentifié côté client, + SSE S3 par-dessus |
| Réplication / DR | State et artefacts miroités vers un store `-backup` (prod : autre provider, credentials séparés) |
| Accès API Kubernetes | ACL du LB restreinte à `admin_ip` |
| Accès API Talos | Tunnel SSH uniquement (port 50000, jamais sur le LB) |
| Chiffrement inter-nœuds | Cilium WireGuard |
| Gestion des secrets | OpenBao (fork Vault, open source) |

## Roadmap

| Phase | Livrable | Statut |
|-------|----------|--------|
| **3** | OVH + Outscale actifs, hub/spoke Flux, failover cross-provider | ✅ fait |
| **3b** | Management amorcé par CAPI + pivot autogéré | ✅ fait |
| **4** | `providerID` sur les nœuds CAPI (CCM ou kubelet) → MachineHealthCheck | ⏳ prioritaire |
| **4b** | Failover DNS (ExternalDNS + k8GB), auto-unseal OpenBao | ⏳ prévu |
| **5** | Catalogue de services (Kratix / Backstage) | ⏳ prévu |

## Licence

**OpenAether** est distribué sous
[GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Source : **https://github.com/dis-bzh/OpenAether-infra**
