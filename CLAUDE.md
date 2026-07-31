# CLAUDE.md — OpenAether-infra

Provisioning bare-metal / cloud + Talos (OpenTofu). Les manifests communs et le
wiring Flux vivent dans `OpenAether-apps` ; les manifests **métier** dans chaque
repo applicatif.

## Dépôt public — aucune donnée réelle

Ce dépôt est **public**. N'y committer que du code et des exemples — jamais une
IP, un ID de compte cloud, ou toute autre donnée propre à un environnement ou un
test réels. Pattern déjà en place : `envs/*.tfvars` (réel) est gitignore, seul
`*.tfvars.example` (placeholders `YOUR_IP`, etc.) est public. Incident du
2026-07-31 : des IP réelles (FIP OVH, egress management, IP admin) avaient fui
dans `OpenAether-apps` et ont nécessité une purge d'historique (`git
filter-repo`, `--replace-text` ET `--replace-message` — les messages de commit
ne sont PAS couverts par le premier seul).

## Objectif produit — socle Talos modulaire, management CAPI optionnel

OpenAether déploie **un cluster Talos** sur **n'importe quel provider** (Proxmox ou
cloud Scaleway/OVH/Outscale) avec pour **seul socle figé : CNI (Cilium) + Flux**.
Par-dessus, on **pioche modulairement** dans les manifests communs d'`OpenAether-apps`
selon les dépendances voulues (mesh ou non, Zitadel sans OpenBao, Harbor + OpenBao,
etc.). Les manifests **applicatifs métier** restent dans chaque repo d'app (ex.
`seestar-fits`) et dépassent ce projet.

Un cluster ne devient un **cluster de management** que lorsqu'on y installe/configure
**CAPI + ses dépendances** pour piloter des clusters clients. Le multi-cluster reste
un objectif — mais devient une **surcouche optionnelle**, plus le point d'entrée
(ce n'est ni le plus simple ni le plus cheap). Ce recentrage **élargit** l'usage
d'OpenAether : du single-cluster autonome jusqu'au hub multi-cluster.

**Topologie paramétrable** : HA (3 CP + n workers) ou non-HA (1 CP + 1 worker), via
`control_plane_count` / `worker_count`. En non-HA, CP taché `NoSchedule` (workloads
sur le worker sans nodeSelector).

### Ajout provider Proxmox (on-premise)

Cible d'hébergement des apps DIS (seestar-fits, prospection, multisport…) : serveurs
dédiés sous **Proxmox** (ZFS), VMs Talos. Single-host ou multi-host PVE cluster.

- **Nouveau provider `proxmox`** sous `modules/providers/proxmox/`, respectant
  `modules/providers/provider-contract.md` — mêmes variables/outputs que `scw`/`ovh`/
  `outscale` (`control_plane_count`, `worker_count`, IPs privées CP/worker, LB
  k8s/app, bastion). Le reste du stack (module `talos`, `cluster/`) est
  provider-agnostique et **ne doit pas changer**.
- **`node_names` (list)** : VMs round-robinées via `element()` (même pattern que
  les zones Scaleway). `["pve1"]` = non-HA, `["pve1","pve2","pve3"]` = vrai HA
  (1 CP par hôte physique, etcd distribué).
- **VIP apiserver posé dès le 1 CP** : endpoint k8s sur une VIP Talos (pas l'IP nue
  du CP) pour que le passage futur à 3 CP ne re-adresse pas l'apiserver.
- HA réelle du CP on-premise = **multi-hôtes** (3 CP sur 3 dédiés dans un cluster
  PVE) ; 3 CP sur une seule box Proxmox n'est pas de la vraie HA.
- `k3s-cluster` = **archive / inspiration seule**, jamais fusionnée ; refaire de 0 si
  plus propre.

## Langue

**L'anglais est la langue par défaut du dépôt** : commentaires de code, noms,
messages de commit et documentation. Le français est une **traduction**, jamais
la source.

- Docs et README : `<nom>.md` = anglais (canonique), `<nom>.fr.md` = français.
  Chaque fichier ouvre sur un lien vers l'autre langue.
- Code (`.tf`, `.yaml`, `.py`, `.sh`) : commentaires en anglais.
- Échange avec l'utilisateur : en français.

⚠️ Toute régression est un défaut : écrire directement en anglais. La bascule
du 2026-07-28 s'est faite par lots et en a laissé passer — le 2026-07-29 il
restait ~50 lignes dans les deux dépôts, dont des blocs à moitié traduits où une
phrase française coupait une phrase anglaise. Ne pas se fier à « c'est déjà
fait » : passer le détecteur.

**Piège vécu lors de cette bascule** : `pick.py` identifiait ses profils générés
par la chaîne littérale française de leur en-tête. La traduire a rendu `--check`
aveugle **en silence** (il annonçait « 0 profil » au lieu de 1). Avant de
traduire une chaîne, vérifier qu'aucun code ne la compare.

## Concision et refacto

Le projet ne doit pas grossir en lignes plus vite qu'en fonctionnalités.

- **Commentaire = le pourquoi, en 1 à 3 lignes.** Pas le récit de l'incident ni
  la date : juste ce qui évite de refaire l'erreur. Le détail va dans le runbook.
- **Doc courte qui POINTE** vers le fichier faisant autorité, au lieu de
  recopier son contenu (la recopie dérive, et il faut la maintenir deux fois).
- **Backlog = ouvert seulement.** Une entrée faite appartient à git.
- **Refactorer au fil de l'eau** : factoriser les répétitions, supprimer le code
  mort, fusionner les fichiers redondants. Un fichier qui gonfle est un signal.

Avant d'écrire un pavé : que perd-on à le réduire à deux lignes ? Le plus
souvent, rien.

## Backlog

Toute amélioration identifiée (« mieux que l'existant ») va dans
**`docs/backlog.md`** — le lire en début de chantier, y ajouter les découvertes,
retirer ce qui est fait. Sa section **« Où on en est »** (en tête) dit ce qui
tourne, ce qui est validé en cloud réel et par où reprendre : **c'est le premier
fichier à ouvrir en début de session**. Parcours post-déploiement :
`docs/admin-access.md`.

Avant de toucher au DAG Flux d'`OpenAether-apps` : `task apps-validate`
(intégrité du DAG + profils `pick.py` à jour).

## Repère structure

- `infrastructure/opentofu/modules/providers/` : un dossier par provider + `_shared`
  + `provider-contract.md` (le contrat à implémenter).
- `infrastructure/opentofu/cluster/` : composition (Talos, bootstrap-manifests, envs).
- `infrastructure/opentofu/talos-image/` : build de l'image Talos (schematic).
