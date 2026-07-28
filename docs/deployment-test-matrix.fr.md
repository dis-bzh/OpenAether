# OpenAether-infra — Matrice de test des déploiements

🇬🇧 [English version](deployment-test-matrix.md)

> Liste exhaustive et dédoublonnée des cas de déploiement que ce stack peut
> produire, et de ceux réellement exercés. Dérivée du code
> (`cluster/variables.tf`, `cluster/main.tf`, les cinq modules provider,
> `modules/talos/variables.tf`, `provider-contract.md`, `Taskfile.yml`, et les
> `envs/*.tfvars.example`).
>
> Légende : ✅ testé par apply réel · 🧪 testé unitairement seulement
> (`tofu test`, mocké) · ⬜ non testé
>
> Dernière revue : **2026-07-28**.

## Modèle mental

Un **fichier d'env = un cluster = un provider**. `cluster/main.tf` impose un
seul provider actif par apply (`check "single_provider_per_cluster"`) ; le
provider actif est celui dont la clé `node_distribution.<provider>` a
`control_planes + workers > 0`. Le module provider rend l'infra (LB / réseau /
bastion) ; puis `modules/talos`, **provider-agnostique**, rend une config Talos
identique quel que soit le provider. Le Docker local est une **racine séparée**
(`infrastructure/opentofu-local`), non sélectionnable via `node_distribution`.

Deux couches de réglages orthogonales :

- **Forme de l'infra** (par provider) : provider, zones/hôtes, `k8s_lb_mode`,
  bastion, disques workers.
- **Talos / exploitation** (agnostique) : `cluster_role`, phase
  `talos_bootstrap`, injection de VIP, `secrets_prevent_destroy`,
  `auto_tunnels`, `backup_enabled`, raccourcis réservés aux tests.

## A) Dimensions

| Dimension | Chemin de la variable | Valeurs | Défaut | Applicabilité | Notes |
|---|---|---|---|---|---|
| Provider | `node_distribution.<clé>` (scaleway/ovh/outscale/proxmox) ; `local` = racine `opentofu-local` séparée | un seul actif | `{}` | — | Exactement un actif par apply. |
| Rôle du cluster | `cluster_role` | `management`, `workload` | `workload` | tous | Ne pilote que le manifeste d'amorçage Flux. Un « management » reçoit ensuite CAPI et ses dépendances via `OpenAether-apps` (aucun réglage CAPI côté tofu). `failover-*` = rôle management sur un provider non primaire. |
| Environnement | `environment` | `dev`, `prod` | requis | tous | Nommage / suffixe de bucket seulement — pas un axe de topologie. |
| Topologie CP (HA) | `node_distribution.<p>.control_planes` ; local `control_plane_count` | 1 = non-HA, 3 = HA | 0 / local 3 | tous | Le quorum etcd exige un nombre impair ≥ 3. CP non-HA taché `NoSchedule`. |
| Nombre de workers | `node_distribution.<p>.workers` ; local `worker_count` | ≥ 0 (local `0..3`) | 0 / local 3 | tous | 0 worker → workloads sur les CP (non tachés). |
| Mode LB k8s | `node_distribution.<p>.k8s_lb_mode` | `managed`, `vip` | `managed` | **scw, ovh** seulement ; outscale = managed seul (rejette vip) ; proxmox = toujours VIP ; local = ni l'un ni l'autre | `vip` (EXPÉRIMENTAL) : pas de LB, adresse IPAM privée + VIP Talos Layer2 → **API privée uniquement, via tunnel bastion**. |
| VIP apiserver | `local.apiserver_vip` → `module.talos.apiserver_vip` ; proxmox `apiserver_vip` (requis) + `apiserver_vip_interface` | IP / null | null (cloud) ; requis (proxmox) | proxmox toujours ; scw/ovh en mode vip | Injecté en `machine.network.interfaces[].vip` + certSANs. Ignoré en mode conteneur. |
| LB applicatif | (pas de bascule) contrat `app_lb_ip` | inhérent au provider | actif | scw/ovh/outscale créent un LB applicatif (80/443) ; proxmox = DNAT hôte ; local = `127.0.0.1` | Pas un axe de test. |
| Zones / AZ | scw `.zone`+`.zones` ; ovh/outscale `.availability_zones` ; proxmox `.node_names` (round-robin) | ex. scw `["fr-par-1","fr-par-2","fr-par-3"]` | selon exemple | cloud + proxmox | Mono vs multi-AZ. Proxmox : 1 hôte = non-HA, 3 hôtes = **vraie** HA ; 3 CP sur 1 hôte = fausse HA (à éviter). |
| Bastion | proxmox `enable_bastion` | `true` (VM) / `false` (hôte-bastion) | `false` | bascule proxmox ; scw/ovh/outscale = toujours une VM dédiée ; local = aucun | Le contrat exige `bastion_ip`. |
| Stockage workers | `worker_storage.disks[]` + `worker_storage.volumes[]` (LUKS2 `UserVolumeConfig`) | aucun, ou disques+volumes | `{disks=[],volumes=[]}` | scw/ovh/outscale/proxmox ; local forcé à off | `disks` → module provider ; `volumes` → `modules/talos`. |
| Phase d'amorçage | `talos_bootstrap` | `false` (phase 1 infra), `true` (phase 2 config+etcd+Flux) | `true` | tous | `task infra` → `task bootstrap-phase2`. |
| auto_tunnels | `auto_tunnels` (+ `ssh_key_path`) | `true`/`false` | `false` | cloud/proxmox | EXPÉRIMENTAL, apply unique ; jamais testé sur machine réelle. |
| secrets_prevent_destroy | `secrets_prevent_destroy` | `true`/`false` | `true` | tous | `false` réservé au nettoyage de `tofu test`. |
| skip_port_ready_wait | `skip_port_ready_wait` | `true`/`false` | `false` | tous | `true` réservé à la CI mockée. |
| backup_enabled | `backup_enabled` | `true`/`false` | `true` | racine | `false` saute le local-exec de backup. |
| Versions Talos / K8s | `talos_version`, `kubernetes_version` | chaînes | selon exemple | tous | Pilote la résolution du nom d'image. |
| admin_ip | `admin_ip` (liste) | CIDR | requis | tous | Liste d'autorisation ACL LB / SG / nftables hôte. |

## B) Cas de test pertinents

### Exclus / invalides / redondants — à **ne pas** tester

| Combinaison | Pourquoi |
|---|---|
| ≥ 2 providers avec un compte > 0 dans un même apply | Bloqué par `check "single_provider_per_cluster"`. |
| `outscale` + `k8s_lb_mode="vip"` | La validation du provider le rejette (LB à nom DNS). |
| `proxmox` + n'importe quel `k8s_lb_mode` | Ignoré — proxmox utilise toujours la VIP Talos. |
| `local-docker` + LB / stockage / Flux par manifeste d'amorçage | Pas de LB (IP du cp0) ; volumes forcés off ; Flux installé après boot. |
| `apiserver_vip` avec `k8s_lb_mode="managed"` en cloud | Résout à null. |
| 3 CP sur un seul hôte Proxmox | Fausse HA — la vraie HA est multi-hôtes. |
| local CP ∉ {1,3} ou workers > 3 | Erreur de validation. |
| `dev` vs `prod` comme topologie | Nommage seulement — à replier dans n'importe quel cas. |

### local-docker (racine `opentofu-local`)

| ID | CP/W | Ce qu'il exerce en propre | Statut |
|---|---|---|---|
| `L-ha` | 3+3 | Vrai quorum etcd à 3 nœuds, workers dédiés ordonnançables, Cilium, livraison par `userdata` — preuve principale de `modules/talos` sans credentials. | ✅ (`task local-up`, 2026-07-28) |
| `L-smoke` | 1+0 | Smoke test mono-nœud ; repli d'ordonnancement sur CP non taché. | ⬜ |

### Scaleway (provider de référence)

| ID | Rôle | CP/W | k8s_lb_mode | Zones | Stockage | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|---|---|
| `SCW-mgmt-nonha` | mgmt | 1+1 | managed | mono | aucun | Chemin cloud le moins cher ; taint CP non-HA ; ACL du LB managé. | ✅ |
| `SCW-mgmt-ha` | mgmt | 3+2 | managed | 3 AZ | aucun | etcd sur 3 zones ; distribution multi-AZ. | ⬜ |
| `SCW-vip` | mgmt | 3+1 | **vip** | multi-AZ | aucun | Supprime le LB ; VIP Talos Layer2 ; API privée via tunnel ; anti-spoofing. | ✅ *(2026-07-15)* |
| `SCW-work-ha` | workload | 3+3 | managed | 3 AZ | aucun | Chemin d'amorçage Flux du rôle workload. | ⬜ |
| `SCW-storage` | workload | 3+3 | managed | 3 AZ | **disques+volumes** | Volumes blocs SBS + `UserVolumeConfig` chiffré (LUKS2). | ⬜ |

### OVH (OpenStack)

| ID | Rôle | CP/W | k8s_lb_mode | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|
| `OVH-mgmt-ha` | mgmt | 3+3 | managed | LB Octavia + floating IP ; ports OpenStack ; bastion Ubuntu ; egress routeur SNAT. | ✅ *(2026-07-27/28, plusieurs cycles)* |
| `OVH-vip` | mgmt | 3+2 | **vip** | `allowed_address_pairs` sur les ports CP pour l'anti-spoof Neutron (mécanisme distinct de Scaleway). | 🧪 |
| `OVH-work-ha` | workload | 3+3 | managed | Rôle workload sur OVH. | ⬜ |
| `OVH-storage` | workload | 3+3 | managed | Attachement de volumes Cinder. | ⬜ |

### Outscale (managed seul, LB à nom DNS)

| ID | Rôle | CP/W | k8s_lb_mode | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|
| `OSC-mgmt-ha` | mgmt | 3+2 | managed | Le LB renvoie un **nom DNS**, pas une IP ; utilisateur SSH outscale. | ✅ |
| `OSC-work-ha` | workload | 3+3 | managed | Rôle workload ; volumes BSU si couplé au stockage. | ⬜ |
| `OSC-vip-reject` | — | tout | vip | Test négatif : la validation doit rejeter `vip`. | 🧪 |

### Proxmox (bare-metal, toujours VIP, hôte-bastion)

| ID | Rôle | CP/W | node_names | Bastion | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|---|---|
| `PMX-nonha-host` | mgmt | 1+1 | `["pve1"]` | hôte | Mono-hôte non-HA ; VIP Talos ; IP statiques `cidrhost()` ; ni LB ni NAT ni SG. | ⬜ |
| `PMX-work-nonha` | workload | 1+1 | `["pve1"]` | hôte | Rôle workload on-prem. | ⬜ |
| `PMX-ha-multihost` | mgmt | 3+n | `["pve1","pve2","pve3"]` | hôte | Vraie HA on-prem : 1 CP par hôte, VIP qui flotte ; bridge L2. | ⬜ |
| `PMX-vm-bastion` | mgmt | 1+1 | `["pve1"]` | **VM** | Chemin bastion en VM dédiée. | ⬜ |
| `PMX-storage` | workload | 1+1 | `["pve1"]` | hôte | Disque de données Proxmox + volume chiffré. | ⬜ |

### Surcouche CAPI — clusters enfants et management amorcé par CAPI

| ID | Amorcé par | Provider | Ce qu'il exerce en propre | Statut |
|---|---|---|---|---|
| `CAPI-edge-scw` | management | Scaleway | Enfant CAPS ; Cilium+Flux injectés à distance ; profil git propre. | ✅ *(edge-1, 2026-07-28)* |
| `CAPI-edge-ovh` | management | OVH (CAPO) | Enfant CAPO ; réseau/LB/SG créés par CAPO ; FIP pré-allouée pour les certSANs. | ✅ *(edge-2, 2026-07-28)* |
| `CAPI-cross-provider` | management OVH | Scaleway | Gitception **cross-provider dans les deux sens**. | ✅ *(2026-07-28)* |
| `CAPI-mgmt-pivot` | cluster jetable local | Scaleway | Management **né de CAPI**, qui déploie son propre enfant, puis `clusterctl move` vers lui-même. | ✅ *(mgmt-capi, 2026-07-28 — cf. `capi-bootstrap.fr.md`)* |
| `CAPI-edge-osc` | management | Outscale | Enfant CAPOSC. | ⬜ *(quota RAM du compte)* |

### Scénarios d'exploitation transverses

| ID | Variables clés | Ce qu'il exerce en propre | Statut |
|---|---|---|---|
| `OP-twophase` | `talos_bootstrap=false` puis `true` | Découpage documenté `task infra` → `task bootstrap-phase2`. | ✅ |
| `OP-autotunnels` | `auto_tunnels=true` | EXPÉRIMENTAL, apply unique. | ⬜ |
| `OP-failover` | `failover-<p>.tfvars`, `task failover` | 2ᵉ management cross-provider ; ré-enregistrement des spokes. | ⬜ |
| `OP-destroy` | `task fleet-down` / `task destroy` | Chemin de destruction ordonné (enfants puis management). | ✅ |
| `OP-tftest` | mocké | Suite de tests unitaires (sans credentials). | ✅ (CI) |
| `OP-backup` | `backup_enabled=true`, `BACKUP_AWS_*` cross-provider | DR : tfstate + kube/talosconfig vers primaire et réplica ; restic chiffré client. | ✅ *(local + cloud réel SCW+OVH)* |
| `OP-rolling-replace` | `task rolling-replace` | Remplacement d'un nœud sans coupure (evict etcd, 1 nœud à la fois). | ✅ *(Scaleway)* |

## C) Priorités (plus forte valeur, non testé, apply réel)

1. **`providerID` sur les nœuds CAPI** — aucun enfant n'a de `spec.providerID`,
   donc `nodeRef` n'est jamais résolu et `MachineHealthCheck` est inopérant.
   Bloquant pour l'argumentaire day-2 de CAPI. Cf. `backlog.md`.
2. **Apply réel Proxmox** (`PMX-*`) — jamais exécuté sur un hôte réel.
3. **HA multi-AZ en cloud** (`SCW-mgmt-ha`, `OSC-mgmt-ha`) — etcd 3 CP réparti
   sur plusieurs zones jamais appliqué.
4. **`OVH-vip`** — le mode vip n'a jamais été appliqué sur OVH (mécanisme
   Neutron `allowed_address_pairs`, distinct de Scaleway).
5. **Apply réel du rôle workload** (`*-work-*`) — seul le management est exercé.
6. **`worker_storage` en réel** (`*-storage`) — LUKS2 `UserVolumeConfig` et
   attachement de volumes jamais appliqués.
7. **`OP-failover`** — chemin DR non prouvé.

## D) Constats — apply réel `SCW-vip` (2026-07-15)

3 CP (fr-par-1 + fr-par-2) + 1 worker, `k8s_lb_mode=vip`.

- ✅ **La VIP Layer2 fonctionne sur Scaleway, y compris cross-zone.** Le réseau
  privé régional relaie l'ARP de la VIP entre zones — c'était la principale
  inconnue.
- ✅ **La VIP est dans les SANs du certificat apiserver.**
- ⚠️ **L'accès opérateur est privé uniquement** : il faut le tunnel bastion 6443.
- ⚠️ **`data.talos_cluster_health` peut bloquer l'apply en deux phases en mode
  vip** : la lecture part du poste opérateur et n'atteint pas la VIP privée. etcd
  et la config sont appliqués avant, donc le state est complet.

## E) Tenir ce document à jour

1. **Ce fichier versionné** est l'artefact vivant : maintenir la colonne
   **Statut** de chaque cas.
2. **Générer les lignes « combinaisons livrées » depuis `envs/*.tfvars.example`**
   pour que la table ne dérive pas ; garder au-dessus la prose écrite à la main.
3. **Lier le statut aux filtres `tofu test`** pour distinguer explicitement
   « couvert (unitaire) » de « couvert (apply) ».
4. **Garde-fou CI** : échouer si un nouveau champ `node_distribution` ou une
   nouvelle valeur d'énumération apparaît dans `variables.tf` sans ligne
   correspondante ici.
