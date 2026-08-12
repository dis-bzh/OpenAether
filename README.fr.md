# OpenAether-infra

> **Store Anywhere, Run Anywhere.**
> Un cluster Talos idempotent sur n'importe quel environnement — local (Docker),
> on-prem (Proxmox) ou cloud (Scaleway/OVH/Outscale) — avec pour seul socle figé
> **CNI (Cilium) + Flux**. Tout le reste se pioche dans `OpenAether-apps`.

🇬🇧 [English version](README.md)

## Version

**1.0.1** — socle Talos modulaire multi-provider (cf. `CHANGELOG.md`). Déploie
le tag `OpenAether-apps` correspondant : une version identifie un système.

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
**[docs/capi-bootstrap.fr.md](docs/capi-bootstrap.fr.md)**.

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
Talos/cluster est provider-agnostique. Détail : `docs/deployment-test-matrix.fr.md`.

| Provider | Statut | Région / cible | Notes |
|----------|--------|----------------|-------|
| **Scaleway** | ✅ management validé | fr-par (3 AZ) | Implémentation de référence ; rolling-replace exercé en réel |
| **OVH** | ✅ management validé | EU-WEST-PAR (OpenStack) | LB Octavia, floating IPs, routeur SNAT, réseau privé |
| **Outscale / Numspot** | ✅ management validé | eu-west-2 | LB, NAT-service, sous-réseaux public/privé, VPC |
| **Proxmox (on-prem)** | 🧪 code-complet, testé unitairement — **jamais appliqué en réel** | PVE mono/multi-hôte | VIP Talos (pas de LB managé), NAT/DNAT nftables, prérequis manuels |
| **Local (Docker)** | ✅ validé (`task local-up`) | WSL2 / Docker | 3 CP + 3 workers, quorum etcd, Cilium — preuve sans credentials de `modules/talos` |

## Structure du dépôt

```
infrastructure/opentofu/
  cluster/        # racine cluster (management + workload) ; envs/ = un tfvars par cluster
  talos-image/    # constructeur d'image, state à part
  opentofu-local/ # racine Docker locale, réutilise modules/talos
  modules/talos/  # secrets, config, bootstrap — provider-agnostique
  modules/providers/{scw,ovh,outscale,proxmox,local}/   # provider-contract.md = le contrat
scripts/
  bootstrap/  # cycle de vie (rare)
  ops/        # exploitation : fleet-down, edge-down, rolling-replace, etcd-snapshot,
              # preflight-quotas, check-cilium-parity, purge-orphans…
  internal/   # appelés par le Taskfile
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
paramétrable (`talos_api_port_base`, défaut 45000). Diagnostiquer avec
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

### Cluster de management (cloud)

```bash
source .env.sh

cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \
   infrastructure/opentofu/cluster/envs/management-scaleway.tfvars
# Éditer : admin_ip, bastion_ssh_keys, image_name/image_id, s3_primary_*/s3_replica_*
# Et git_repo_url + git_ref si tu utilises ton propre fork d'OpenAether-apps —
# les défauts pointent sur le nôtre, et son apps/clusters n'est pas le tien.

task preflight-quotas PROVIDER=ovh          # vérifier les quotas d'abord
task talos-image PROVIDER=scaleway          # une fois par version d'image
task infra ROLE=management PROVIDER=scaleway
task bootstrap-phase2 ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

**Après le déploiement** : suivre le parcours jour-1
([docs/admin-access.fr.md](docs/admin-access.fr.md)) — escrow Shamir/root/restic,
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
(cf. `docs/capi-bootstrap.fr.md`).

### Cloud émulé (Feint — sans compte cloud, sans credentials)

Pointe les **vrais** providers Scaleway et Outscale vers un émulateur local de
leurs APIs. Un cran au-dessus du `tofu test` mocké : vrai HTTP, vrai décodage,
aucune facture.

```bash
task feint-up                        # démarre l'émulateur (binaire épinglé, checksum vérifié)
task feint-plan   PROVIDER=scaleway  # plan du VRAI root cluster, zéro credential
task feint-apply  PROVIDER=outscale  # cycle apply/destroy sur la fixture réduite
task feint-record PROVIDER=scaleway  # classe les opérations qu'on appelle et qu'aucun pack ne sert
task feint-down
```

⚠️ Ça ne prouve **pas** qu'un déploiement réel fonctionne — l'émulateur n'a ni
inventaire, ni load balancer, ni quotas. Cf.
[docs/emulated-cloud.fr.md](docs/emulated-cloud.fr.md).

### Contrôles statiques (sans cloud ni Docker)

```bash
task validate            # tofu fmt/validate/test
task apps-validate       # intégrité du DAG Flux + profils pick.py à jour
task security            # contrôles de durcissement
```

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/admin-access.fr.md](docs/admin-access.fr.md) | Parcours jour-1 : escrow, PKI offline, accès UIs, tests navigateur |
| [docs/capi-bootstrap.fr.md](docs/capi-bootstrap.fr.md) | Amorcer un management par CAPI et le rendre autogéré |
| [docs/deployment-test-matrix.fr.md](docs/deployment-test-matrix.fr.md) | Ce qui est validé, où, et comment |
| [docs/emulated-cloud.fr.md](docs/emulated-cloud.fr.md) | Tester Scaleway/Outscale contre un émulateur local — et les limites de l'exercice |
| [docs/release-checklist.md](docs/release-checklist.md) | Ce qu'il faut lancer avant de taguer, dans l'ordre qui échoue le moins cher |
| [docs/backlog.md](docs/backlog.md) | **Source de vérité** : état courant, dette, améliorations (anglais seulement) |

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

**OpenAether** est distribué sous [licence Apache 2.0](LICENSE). Le projet était
sous AGPLv3 jusqu'à la 1.1.0 ; le changement est un assouplissement, donc ce que
vous déteniez déjà sous AGPLv3 le reste.

Source : **https://github.com/dis-bzh/OpenAether-infra**
