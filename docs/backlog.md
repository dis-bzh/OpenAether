# Backlog — améliorations identifiées (source de vérité)

Tout ce qui a été identifié comme **mieux que l'existant**, avec le pourquoi.
Alimenté au fil des sessions (humain + assistant). Retirer les entrées faites.

## Où on en est (mis à jour le 2026-07-26)

**Aucune infrastructure cloud ne tourne** — la flotte a été détruite en fin de
session (`task fleet-down PROVIDER=outscale` : 2 enfants CAPI en cascade puis
67 ressources OpenTofu). Vérifié à zéro sur les **trois** comptes : Outscale
(VMs, volumes, LB, IP, Nets), Scaleway (fr-par-1/2) et OVH — une FIP orpheline
y a été purgée (`scripts/ops/purge-orphans/ovh.py --apply`). Tout repart de zéro
via `task up`.

Conservé volontairement (le détruire coûte du temps ou de la restaurabilité) :
buckets S3 (tfstates, artefacts, **dépôts restic**) et images Talos v1.13.4 sur
les 3 clouds (~1 h de rebuild sur Outscale). À recréer au prochain run car créés
hors OpenTofu : keypair Outscale `openaether-capi`, FIP OVH pré-créée (certSAN).
⚠️ Les dépôts restic survivent aux clusters, **pas leur `RESTIC_PASSWORD`** :
réutiliser un bucket sans son escrow bloque les backups (« already initialized »).
Le fichier `infrastructure/opentofu/cluster/restic-escrow-OUTSCALE.txt` a donc
été **volontairement conservé** — il déverrouille les dépôts restés en bucket.
Les `kubeconfig` / `talosconfig` / `edge-*.kubeconfig` ont eux été supprimés
(ils pointaient vers des clusters qui n'existent plus).

Ce qui est **validé en cloud réel** :

- Le socle est **provider-agnostique pour de vrai** : le même code a porté un
  cluster de management successivement sur **Scaleway, OVH et Outscale**, chaque
  provider ayant révélé (puis fait corriger) des défauts propres. Dernier run :
  management Outscale HA, **DAG 32/32**, 6 nœuds Ready.
- **Backups** restic chiffrés client, multi-destination et **cross-provider**
  (primary Outscale → replica Scaleway), validés dans les trois sens.
- **Pioche modulaire** (`scripts/pick.py`) : fermeture transitive des `dependsOn`,
  profils générés, garde-fou anti-drift (`--check`, `task apps-validate`).
- **Kubeception/gitception** : le management provisionne des enfants Talos via
  CAPI puis y injecte Cilium+Flux à distance ; les enfants réconcilient leur
  propre profil. Fonctionnel de bout en bout sur Scaleway et OVH.
- **Résilience** : reboot simultané non sollicité des 6 VMs Outscale (événement
  plateforme) — le cluster est revenu seul, sans intervention.

Ce qui **reste ouvert** (par ordre d'importance pour reprendre) :

1. **Les enfants CAPI ne sont pas fiables en mutation.** Le dernier run les a
   dégradés en changeant leurs values Cilium à chaud (edge-1 11/17, edge-2
   0/17). Le correctif de fond est en place pour les **prochains** enfants ;
   il n'a jamais été validé sur un enfant créé from scratch avec ces valeurs.
   → **Premier chantier : recréer un edge et vérifier qu'il atteint 17/17.**
2. `apiserver → kubelet:10250` injoignable sur l'edge OVH (diagnostic à
   distance impossible) — cf. section CAPI.
3. Divergence `socketLB.hostNamespaceOnly` parent/enfant, inexpliquée.
4. Les deux branches Git à garder synchro (cf. « Dette de process »).

## Identités & accès au quotidien (le chantier ouvert)

- [ ] **Tokens OpenBao nominatifs** : policies admin dédiées + `bao token create`
      (ou auth OIDC), bannir l'usage quotidien du root token. Aujourd'hui :
      root token dans le Secret `openbao-recovery`.
- [ ] **Wave 3 unsealer** : escrow direct Bitwarden EU des parts Shamir,
      suppression du Secret etcd `openbao-recovery` (TODO déjà tracé dans
      `unsealer.yaml` + CNP egress Bitwarden).
- [ ] **SSO Grafana ↔ Zitadel (OIDC)** : Zitadel est déployé pour ça ; Grafana
      est en admin local. Ensuite : OpenBao login OIDC via Zitadel, et Longhorn
      UI derrière authn (ext-authz Istio ou oauth2-proxy).
- [ ] **Wave 2 OpenBao TLS interne** (`tls_disable=1` actuellement, TODO tracé).

## CAPI / multi-cluster

- [x] ~~Collision secrets webhook capi-system~~ → FAIT (2026-07-25) : Outscale
      isolé dans `capi-outscale-system`. Corrigeait AUSSI une 2e collision
      (lease `controller-leader-election-capo` partagé avec CAPO, qui bloquait
      entièrement OpenStack).
- [ ] **Issues upstream à ouvrir** (les deux constatées en réel) :
      (a) CAPOSC/CAPS : `webhook-server-cert` et le lease `…-capo` non préfixés
      → collisions silencieuses entre providers dans un même namespace ;
      (b) CAPS : reconcile silencieusement arrêté quand son webhook de
      conversion est cassé (aucun log), suppression bloquée sur finalizers.
- [ ] **Outscale : import de snapshot très lent** — OMI Talos v1.13.4 restée
      `in-queue` 0% > 40 min (timeout du provider). Prévoir un timeout plus long
      dans le module, et surtout ne PAS `-replace` l'image tant que la nouvelle
      n'est pas `completed` (le destroy préalable a supprimé l'OMI v1.13.3).
- [ ] **Purge du staging Outscale** : `s3-openaether-outscale-talos-staging`
      conserve un .raw de 4,1 Go par version, jamais supprimé après import.
- [ ] **DETTE — state talos-image Outscale désynchronisé** (2026-07-25) : l'OMI
      `ami-6711ec55` (Talos v1.13.4, variante aws) a été enregistrée VIA L'API
      depuis le snapshot `snap-73e9b29e`, parce qu'un `tofu apply` relançait un
      import de ~1 h au lieu de réutiliser le snapshot abouti. À réconcilier :
      `tofu import module.outscale[0].outscale_snapshot.talos snap-73e9b29e` +
      `… outscale_image.talos ami-6711ec55`, sinon le prochain apply recréera
      tout. Un snapshot orphelin (`snap-6bc67b02`, import relancé puis
      abandonné) est également à supprimer — il est facturé.
- [x] **Cilium des enfants désaligné du socle parent** (2026-07-26) : les
      `values` d'`apps/clusters/edge-*.yaml` laissaient `cni.exclusive` au défaut
      du chart (`true`) et `socketLB.hostNamespaceOnly=false`. Cilium réécrivait
      donc `05-cilium.conflist` en boucle en retirant le plugin chaîné istio-cni
      → `istio-cni-node` 0/1 Ready indéfiniment → install Helm expirée → `istio`,
      `ztunnel`, `services-gateway`, `istio-authorizationpolicies` bloqués sur
      les DEUX edges. Corrigé + raison documentée dans les manifests.
- [ ] **`socketLB.hostNamespaceOnly` : parent=true, enfants=false — à comprendre**
      (2026-07-26). Sur un enfant, le passer à `true` casse les webhooks :
      kube-apiserver est host-network et n'atteint plus les ClusterIP de
      `cert-manager-webhook` / du webhook ESO → dry-run Flux en « failed calling
      webhook » sur `cert-manager-issuers`, `external-secrets-stores`, et
      `backup-openbao` bloqué derrière. Le socle parent tourne pourtant avec
      `true` sans ce symptôme (webhooks OK, mesh OK) — la raison de l'asymétrie
      n'est pas élucidée (HA 3 CP vs 1 CP ? datapath ?). En attendant : `false`
      sur les enfants, `true` sur le parent, les deux commentés sur place.
      ⚠️ Ne pas « harmoniser » sans retester les webhooks des deux côtés.
- [ ] **Vérifier l'alignement parent/enfant automatiquement** : ces `values` sont
      recopiées à la main dans chaque `apps/clusters/*.yaml` et redivergeront.
      Piste : les sortir dans un ConfigMap/patch commun, ou un test qui compare
      le `cilium-config` rendu parent vs enfant. Reste `nodeSelectorLabels=true`
      côté parent uniquement (sans usage aujourd'hui, volontairement non propagé).
- [ ] **⚠️ Changer les `values` Cilium d'un enfant EN VIE est risqué** (vécu
      2026-07-26). Le HelmRelease `<edge>-cilium` du management pousse un upgrade
      → rollout du DaemonSet CNI sur un cluster à 2 nœuds sans marge : sur edge-2
      (OVH) le datapath inter-nœuds n'est pas revenu (`cilium-dbg status` :
      `Cluster health 0/2 reachable`), les IP privées des deux nœuds ont changé
      au passage (CP .90→.204→.251, worker .237→.36→.113) et le cluster est
      tombé à 0/17 Kustomizations, pods pourtant tous Running. edge-1 (Scaleway)
      a mieux encaissé (istio-cni enfin Ready, 11/17). **Préférer recréer
      l'enfant** (CAPI) plutôt que muter son CNI en place ; réserver la mutation
      en place aux clusters HA, et un nœud à la fois.
- [ ] **edge-2/OVH : `apiserver → kubelet:10250` en timeout** — `kubectl
      logs/exec` inutilisables sur ce cluster (i/o timeout), alors que
      `kubelet → apiserver` fonctionne (nœuds `Ready`). Empêche tout diagnostic
      à distance. À vérifier : règle de security group CAPO entre les subnets des
      nœuds (le CP et le worker ne sont pas dans le même /24), et `10250` en
      entrée sur le SG worker. Non lié aux rollouts (jamais testé avant).
- [ ] **Deux branches à garder synchro** : le management réconcilie `main`, les
      enfants `feat/pioche-backup-gitception` (`CHILD_BRANCH` dans
      `apps/clusters/*.yaml`). Un correctif poussé sur `main` n'atteint donc PAS
      les edges — piège vécu le 2026-07-26 (fast-forward manuel de la branche).
      À supprimer au merge de la branche (cf. « Dette de process »).
- [ ] **Enfants durcis** : `network.controlPlaneLoadBalancer` (aujourd'hui
      endpoint = IP publique du CP, non-HA) + private network / gateway au lieu
      d'une IPv4 publique par nœud.
- [ ] **Rate-limit GitHub de l'operator CAPI** : fetch anonyme des releases
      (60 req/h/IP) — prévoir fetchConfig avec token ou miroir OCI.
- [x] ~~Teardown des edges non idempotent~~ → FAIT : `task edge-down` (cascade
      CAPI dans le bon ordre) + `task fleet-down` (edges PUIS management, rapport
      de ce qui survit). Le prune Flux seul est documenté comme insuffisant.
      ⚠️ LEÇON (2026-07-26) : la 1re version de fleet-down se contentait d'un
      AVERTISSEMENT quand le management était injoignable (kubeconfig supprimé
      avec le state) puis détruisait quand même → VMs des 3 edges orphelines sur
      les 3 clouds, purgées à la main. Corrigé : arrêt bloquant, `--force-no-edges`
      pour l'assumer explicitement, et un edge-down en échec bloque aussi.
      Scripts de purge d'orphelins industrialisés :
      `scripts/ops/purge-orphans/{ovh,outscale}.py` (+ README) — filet de
      dernier recours, dry-run par défaut.
- [ ] **Moderniser le template Scaleway** : il est en `cluster.x-k8s.io/v1beta1`
      alors que CAPI v1.13 sert `v1beta2` (refs {apiGroup,kind,name}) — passe
      aujourd'hui par conversion, à aligner sur le template OpenStack.
- [ ] **Longhorn/iscsi sur les enfants** : les images Talos OVH/Outscale datent
      d'un schematic antérieur (sans `util-linux-tools`) — reconstruire avant
      de piocher `storage` sur un cluster enfant.

## Backups / DR

- [ ] **Un dépôt restic par cluster (préfixe)** — les dépôts survivent aux
      clusters, mais pas leur `RESTIC_PASSWORD` (regénéré à chaque bootstrap
      d'OpenBao). Résultat, en réutilisant un bucket : le nouveau cluster ne
      peut ni LIRE le dépôt (mauvais password) ni l'initialiser
      ("already initialized") → backups en échec permanent. Constaté au
      déploiement Outscale sur le bucket replica Scaleway laissé par le
      management OVH. Le diagnostic est désormais explicite dans le CronJob ;
      reste à ajouter un **préfixe par cluster** dans le chemin du dépôt
      (env issue du secret backup-restic-env, ex. `<cluster>/openbao`), pour
      que plusieurs clusters puissent partager un bucket sans collision.
      ⚠️ Corollaire opérationnel : purger les préfixes d'un cluster détruit,
      ou son password escrowé devient la SEULE façon de relire ses backups.

- [ ] **Alerting échec backups** : VMRule sur `kube_job_status_failed`
      (namespaces foundation-*) — aujourd'hui un CronJob qui échoue est silencieux.
- [ ] **Test de restauration périodique** : job mensuel `restic restore` vers
      volume jetable (les `restic check` ne lisent que les métadonnées).
- [ ] **PITR CNPG** : activer `barmanObjectStore` en overlay cloud (RPO actuel
      = dump quotidien, 24 h).
- [ ] **Longhorn `backupTarget`** par environnement (Setting non câblé ; volumes
      LUKS → backups chiffrés par construction).
- [ ] **etcd-snapshot planifié** : cron côté opérateur (la task existe, rien ne
      la déclenche périodiquement).

## Multi-provider / infra

- [ ] **Quota RAM Outscale : un management HA sature le compte** (2026-07-26).
      `memory_limit` = **40 Go**, or un management HA (3 CP + 3 workers en
      tinav5.c2r7p2 = 7 Go + bastion 2 Go) en consomme **44** — dépassement
      toléré à la création, mais TOUTE VM supplémentaire est ensuite refusée :
      `CreateVms → 10042 TooManyResources (QuotaExceeded)`, quel que soit le
      gabarit. Conséquence : sur ce compte, management Outscale HA **et**
      cluster enfant local sont exclusifs (edge-3 désactivé).
      Autres quotas serrés : `core_limit` 20 (14 utilisés), `vm_limit` 10 (7).
      Piège de diagnostic : l'OscMachine reste en `VmNotReady` avec une IP
      réallouée en boucle et AUCUNE erreur dans le CR — il faut lire les logs
      du manager CAPOSC.
      À faire : (a) demander une hausse de quota si la flotte complète est
      voulue sur Outscale ; (b) pré-vol des quotas avant d'instancier un enfant
      (lecture ReadQuotas + somme des gabarits demandés) ; (c) documenter les
      quotas par provider dans admin-access.md.

- [ ] **Reboot simultané de toute la flotte Outscale observé** (2026-07-26,
      14:32→14:34 UTC) : les 6 VMs (3 CP + 3 workers) ont redémarré en 2 min,
      sans action de notre part (aucun apply en cours, objets Node conservés,
      `initialize sequence` Talos = boot froid). Événement plateforme, pas un
      défaut du socle — et le cluster est revenu **seul** (etcd a retrouvé son
      quorum, DAG remonté à 29/32 sans intervention), ce qui valide au passage la
      résilience. Deux enseignements : (a) l'API a été injoignable ~3 min et le
      healthcheck LB 2×10 s corrigé plus tôt a bien borné la coupure ; (b) un
      health check Flux de 15 min (`storage`/Longhorn) expire si le reboot tombe
      pendant sa fenêtre — il repart au reconcile suivant, mais le message
      « health check failed » est alors un faux positif à ne pas sur-interpréter.
      À faire : ne pas conclure à un bug applicatif sans vérifier d'abord
      `talosctl logs machined | head` (heure de boot) sur plusieurs nœuds.

- [x] ~~Images Talos OVH : renommage in-place~~ → FAIT : `replace_triggered_by`
      sur `terraform_data.build` (OVH) et `build_and_upload` (Outscale), +
      `timeouts { create = "120m" }` sur le snapshot Outscale (import > 60 min).
- [x] ~~E2e enfants CAPI OVH + Outscale~~ → FAIT (2026-07-25).
- [x] ~~Management complet hors Scaleway~~ → FAIT (2026-07-26) : management HA
      3 CP + 3 workers sur **OVH**, DAG 30/30, pilotant les 3 edges (SCW, OVH,
      OSC) + backups cross-provider OVH→Scaleway. A révélé 3 défauts du module
      OVH (volumes multiattach, bastion_user, AZ 'any'), tous corrigés.
      RESTE hors Scaleway : rolling-replace live, management Outscale.
- [ ] **FIP des CP OpenStack créée hors CAPI** : `preAllocatedFloatingIPs` exige
      de connaître l'IP avant le boot (certSANs) ; aujourd'hui l'IP est créée à
      la main côté Neutron. Automatiser (tofu ou pré-création scriptée), et
      documenter qu'un pool supprimé en reclaimPolicy=Delete DÉTRUIT l'IP.
- [ ] **`talos_cluster_health` expire sur cluster SAIN — DÉFAUT GÉNÉRIQUE** :
      reproduit à l'identique sur **OVH puis Outscale** (3 CP + 3 workers, tous
      Ready, etcd HEALTH OK sur les 3 CP, DAG Flux complet). Ce n'est donc ni un
      problème de durée (15 min) ni un particularisme provider ; la piste SG est
      écartée (règle inter-node = tout le trafic intra-SG). Non observé sur les
      management Scaleway (à confirmer : lié au HA 3 CP ? à l'accès via un
      endpoint unique tunnelé ?). Contournement : `skip_health_check` (exposé au
      root, activé dans management-{ovh,outscale}.tfvars).
      PROCHAINE ÉTAPE : bump du provider siderolabs/talos (0.11.0 → 0.12.x) et,
      si le défaut persiste, ouvrir une issue upstream avec les traces.
- [ ] ~~timeout trop court en HA multi-AZ~~ (hypothèse invalidée) — sur OVH
      (3 CP + 3 workers) le data source expire alors que le cluster EST sain
      (6/6 Ready, etcd OK), ce qui interrompt l'apply AVANT les outputs
      (kubeconfig/talosconfig) et les backups d'artefacts. Contournement :
      relancer `task bootstrap-phase2` (idempotent) ou `talosctl kubeconfig`.
      À corriger : allonger le timeout du data source.
- [ ] **Proxmox** : premier apply réel (SYS-1) + hardening Ansible hôte (absent
      du repo, seulement documenté).
- [ ] **Ingress public** : trancher CCM (LB managé) vs LB-IPAM — CCM Scaleway
      présent mais hors DAG ; l'app-lb actuel cible worker:80/443 alors
      qu'Envoy écoute en NodePorts (chemin cassé, cf. mémoire).
- [ ] **Observability S3 cloud** : Loki pointe encore `minio/root` en cloud
      (overlay jamais câblé) ; au câblage, penser `rules.dns` sur sa CNP toFQDNs.
- [ ] **`test-local-stack.sh`** : référence `infrastructure/.yamllint` inexistant ;
      fmt bute sur le scratch `_v2/` (à purger).
- [ ] **kyverno background-controller** désactivé (reports cluster absents).

## Reproductibilité des artefacts générés

- [x] **`bootstrap-manifests/cilium*.yaml` avaient divergé de leur générateur** —
      les deux artefacts portaient `cni-exclusive=false`, `bpf-lb-sock-hostns-only=true`
      et `nodeSelectorLabels=true` (édités à la main lors d'un debug ambient),
      valeurs que `render-bootstrap-manifests.sh` ne passait pas : régénérer
      cassait Istio ambient en silence. Les `--set` sont désormais dans le script,
      avec la raison. *(corrigé 2026-07-26)*
- [ ] **Test de non-régression du rendu** : `task render-manifests` devrait
      diffé le rendu contre l'artefact committé (aujourd'hui il l'écrase). Il
      reste des écarts cosmétiques (lignes vides, ordre de clés du ConfigMap)
      entre l'artefact en service et un rendu neuf du chart 1.19.2 — à réduire à
      zéro avant d'automatiser le diff, sinon le contrôle est inexploitable.
- [x] **Profils `pick.py` périmables en silence** : un profil fige la liste des
      Kustomizations *exclues*, donc toute brique ajoutée au DAG est héritée de
      `../base` sans avoir été pioché (vécu : `orc` bloqué sur les edges).
      `pick.py --check` + `task apps-validate` détectent le drift. *(2026-07-26)*

## Dette de process

- [ ] **Merge `feat/pioche-backup-gitception` → main** (2 repos) puis remettre
      `git_branch="main"` dans `cluster/main.tf` + `task bootstrap-phase2`
      (les clusters LIVE réconcilient cette branche).
- [ ] CHANGELOG apps inexistant (l'infra en a un).
