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

- [ ] **Collision secrets webhook capi-system** : CAPS (`caps-serving-cert`) et
      CAPOSC (`…outscale-serving-cert`) écrivent tous deux `webhook-server-cert`
      → cause probable du bug « bad certificate »/reconcile figé (session
      2026-07-25). Fix : un namespace par InfrastructureProvider.
- [ ] **Issue upstream CAPS** : reconcile silencieusement arrêté (aucun log
      manager), suppression bloquée sur finalizers — reproduit une fois.
- [ ] **Enfants durcis** : `network.controlPlaneLoadBalancer` (aujourd'hui
      endpoint = IP publique du CP, non-HA) + private network / gateway au lieu
      d'une IPv4 publique par nœud.
- [ ] **Rate-limit GitHub de l'operator CAPI** : fetch anonyme des releases
      (60 req/h/IP) — prévoir fetchConfig avec token ou miroir OCI.

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

- [ ] **E2e OVH puis Outscale** : même parcours que Scaleway (image, up, DAG,
      backups cross, enfant CAPI). Rolling-replace live hors Scaleway.
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
