# Backlog — améliorations identifiées (source de vérité)

Tout ce qui a été identifié comme **mieux que l'existant**, avec le pourquoi.
Alimenté au fil des sessions (humain + assistant). Retirer les entrées faites.

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
      À AJOUTER : des scripts de purge d'orphelins par provider (ceux écrits
      pendant l'incident sont dans le scratchpad — les industrialiser dans
      scripts/ops/ serait utile : purge-orphans-{ovh,osc}.py).
- [ ] **Moderniser le template Scaleway** : il est en `cluster.x-k8s.io/v1beta1`
      alors que CAPI v1.13 sert `v1beta2` (refs {apiGroup,kind,name}) — passe
      aujourd'hui par conversion, à aligner sur le template OpenStack.
- [ ] **Longhorn/iscsi sur les enfants** : les images Talos OVH/Outscale datent
      d'un schematic antérieur (sans `util-linux-tools`) — reconstruire avant
      de piocher `storage` sur un cluster enfant.

## Backups / DR

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
- [ ] **`talos_cluster_health` expire sur cluster SAIN (OVH HA)** — PAS un
      problème de durée (15 min déjà) : le check etcd du provider talos 0.11.0
      ne converge jamais alors que `talosctl service etcd` répond HEALTH OK sur
      les 3 CP et que les 6 nœuds sont Ready. Piste SG écartée (règle inter-node
      = tout le trafic intra-SG). Contournement en place : `skip_health_check`
      exposé au niveau root + activé dans management-ovh.tfvars. À investiguer
      (bump provider talos ? découverte de nœuds ? endpoint unique via tunnel).
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

## Dette de process

- [ ] **Merge `feat/pioche-backup-gitception` → main** (2 repos) puis remettre
      `git_branch="main"` dans `cluster/main.tf` + `task bootstrap-phase2`
      (les clusters LIVE réconcilient cette branche).
- [ ] CHANGELOG apps inexistant (l'infra en a un).
