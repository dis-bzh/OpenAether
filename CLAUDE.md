# CLAUDE.md — OpenAether-infra

Provisioning bare-metal / cloud + Talos (OpenTofu). Les manifests communs et le
wiring Flux vivent dans `OpenAether-apps` ; les manifests **métier** dans chaque
repo applicatif.

## Décision en cours — cible Proxmox (SYS-1) + Talos non-HA

Contexte : hébergement des apps DIS (seestar-fits, prospection, multisport…) sur un
**serveur dédié OVH SYS-1** (Xeon-E 2136, 32 Go, 2 disques) sous **Proxmox** (ZFS
mirror), VMs **Talos**.

- **Nouveau provider `proxmox`** à ajouter sous
  `infrastructure/opentofu/modules/providers/proxmox/`, respectant
  `modules/providers/provider-contract.md` — mêmes variables/outputs que `ovh` et
  `outscale` (`control_plane_count`, `worker_count`, IPs privées CP/worker, LB
  k8s/app, bastion). Le reste du stack (module `talos`, `cluster/`) est
  provider-agnostique et ne doit pas changer.
- **Topologie non-HA : 1 CP + 1 worker** (`control_plane_count=1`, `worker_count=1`).
  CP taché `NoSchedule` (les workloads atterrissent sur le worker sans nodeSelector).
- **VIP apiserver posé dès le 1 CP** : configurer l'endpoint k8s sur une VIP Talos
  (pas l'IP nue du CP) pour que le passage futur à 3 CP ne re-adresse pas l'apiserver.
- HA réelle du CP = **multi-hôtes** plus tard (3 CP répartis via les providers
  scaleway/ovh/outscale) — 3 CP sur une seule box n'est pas de la vraie HA.
- `k3s-cluster` = **archive / inspiration seule**, jamais fusionnée ; refaire de 0 si
  plus propre.

## Repère structure

- `infrastructure/opentofu/modules/providers/` : un dossier par provider + `_shared`
  + `provider-contract.md` (le contrat à implémenter).
- `infrastructure/opentofu/cluster/` : composition (Talos, bootstrap-manifests, envs).
- `infrastructure/opentofu/talos-image/` : build de l'image Talos (schematic).
