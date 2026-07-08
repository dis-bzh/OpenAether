# CLAUDE.md — OpenAether-infra

Provisioning bare-metal / cloud + Talos (OpenTofu). Les manifests communs et le
wiring Flux vivent dans `OpenAether-apps` ; les manifests **métier** dans chaque
repo applicatif.

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

### Ajout provider Proxmox (SYS-1)

Cible d'hébergement des apps DIS (seestar-fits, prospection, multisport…) : dédié
**OVH SYS-1** (Xeon-E 2136, 32 Go, 2 disques) sous **Proxmox** (ZFS mirror), VMs Talos.

- **Nouveau provider `proxmox`** sous `modules/providers/proxmox/`, respectant
  `modules/providers/provider-contract.md` — mêmes variables/outputs que `scw`/`ovh`/
  `outscale` (`control_plane_count`, `worker_count`, IPs privées CP/worker, LB
  k8s/app, bastion). Le reste du stack (module `talos`, `cluster/`) est
  provider-agnostique et **ne doit pas changer**.
- **VIP apiserver posé dès le 1 CP** : endpoint k8s sur une VIP Talos (pas l'IP nue
  du CP) pour que le passage futur à 3 CP ne re-adresse pas l'apiserver.
- HA réelle du CP = **multi-hôtes** (3 CP répartis via scaleway/ovh/outscale) — 3 CP
  sur une seule box Proxmox n'est pas de la vraie HA.
- `k3s-cluster` = **archive / inspiration seule**, jamais fusionnée ; refaire de 0 si
  plus propre.

## Repère structure

- `infrastructure/opentofu/modules/providers/` : un dossier par provider + `_shared`
  + `provider-contract.md` (le contrat à implémenter).
- `infrastructure/opentofu/cluster/` : composition (Talos, bootstrap-manifests, envs).
- `infrastructure/opentofu/talos-image/` : build de l'image Talos (schematic).
