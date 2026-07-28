# Backlog — améliorations identifiées (source de vérité)

Tout ce qui a été identifié comme **mieux que l'existant**, avec le pourquoi.
Alimenté au fil des sessions (humain + assistant). Retirer les entrées faites.

## Où on en est (mis à jour le 2026-07-28)

⚠️ **UNE FLOTTE OVH TOURNE** — laissée volontairement en fin de run pour
inspection. Management HA **36/36 Kustomizations, 6 nœuds Ready** + enfant CAPI
**edge-2 (OpenStack) 19/19, 2 nœuds, 0 pod en échec**. Teardown :
`task fleet-down PROVIDER=ovh -- --yes`, puis purger la FIP pré-allouée
d'edge-2 (facturée, elle ne part pas seule).

edge-1 (Scaleway) est **désactivé** dans `apps/clusters/kustomization.yaml` : le
périmètre du run était OVH seul. Le réactiver demande les secrets Scaleway.

### Ce que ce run a VALIDÉ en cloud réel

Les 5 chantiers livrés la veille sans jamais avoir tourné :

| Chantier | Preuve |
|---|---|
| Port Neutron du bastion (`fixed_ip`) | 6/6 tunnels SSH |
| **Ingress public** | EndpointSlice → pod réel ; nodePorts **30080/30443** ; pools LB OVH ciblant ces ports |
| PITR CNPG | `s3://…/cnpg/{grafana,zitadel}-db` substitué depuis `cluster-identity` |
| Préfixe restic par cluster | parent `openaether-dev-ovh` **vs** enfant `edge-2` — collision résolue |
| `backupTarget` Longhorn | URL substituée (après correctif d'API, cf. plus bas) |
| Alerting backups | 3 règles acceptées par l'opérateur VM → **le PromQL est valide** |
| TLS interne OpenBao | 3/3 descellés, quorum raft HTTPS, ESO `store validated`, 6 policies en 204 — **et idem sur l'ENFANT**, via gitception |

⚠️ **SSO Grafana ↔ Zitadel : PARTIELLEMENT validé.** Ce qui est prouvé : config
`auth.generic_oauth` chargée avec les bons endpoints, chemin réseau ouvert des
DEUX côtés (CNP egress Grafana → ingress Zitadel, port 8080), et surtout
**Grafana démarre alors que `secret/grafana/oidc` n'est pas seedé** — le
garde-fou `optional: true` remplit son rôle, l'accès n'est pas verrouillé.
**NON validé** : le flux de connexion réel et la STRUCTURE du claim de rôles.
Cela demande de créer l'application côté Zitadel (console) puis de seeder le
secret — étape opérateur, cf. `docs/admin-access.md` § 4bis.

### Ce qui reste à faire au prochain run

1. **Connexion SSO réelle depuis un navigateur** — tout le reste est fait (app
   Zitadel créée, secret seedé, identifiants injectés dans Grafana, scopes
   corrigés). Il ne manque que de se connecter pour confirmer la forme du claim
   retenue. Si tous les comptes restent `Viewer`, inspecter le token et
   substituer l'ID de projet dans `role_attribute_path` (procédure dans le
   fichier).
2. **Chemin gateway → UI** : non testable tant que l'intermediate PKI n'est pas
   signé HORS LIGNE (`admin-access.md` § 2) — le listener HTTPS reste `Invalid`.
   Le code, lui, est durci (`credentialName`, plus d'`insecureSkipVerify`).
3. **Réactiver edge-1** pour re-valider Scaleway.

### Note : les répertoires `local-path` en 0755 (PAS un défaut du code)

Les `initdb` de CNPG ont échoué en `Permission denied` : le répertoire de leur
PVC avait été créé en `0755` au lieu du `0777` que pose le script `setup` du
provisioner. Celui d'OpenBao, créé plus tard, était correct — et le script
déployé était intact (`$VOL_DIR` non vidé, ce qui **valide au passage
l'isolement de la substitution Flux**). Cause probable : le Deployment du
provisioner a roulé **6 fois** pendant le déploiement, sous l'effet des pushes
successifs de correctifs, et une demande de volume est tombée pendant une
transition. Re-provisionner a suffi. À re-vérifier sur un run sans push
intermédiaire avant d'en faire une entrée de dette.

## Défauts trouvés par le run cloud du 2026-07-28

Quatre défauts réels, **aucun visible en analyse statique ni en test local** :

- [x] ~~**Associations de floating IP OVH sans `depends_on` routeur**~~ — Neutron
      refuse l'association tant que le subnet n'a pas de route externe. Course →
      échec **intermittent**. Les TROIS associations étaient concernées ; seul le
      bastion a perdu la course. Suite directe du correctif `fixed_ip` de la
      veille : supprimer la première course a révélé la seconde.
- [x] ~~**Brique OpenBao non conforme aux policies Kyverno du projet**~~ —
      `seccompProfile` au niveau du pod et non PAR CONTENEUR, et image
      `alpine/k8s` sans préfixe de registre. **Ces violations existaient depuis
      toujours** mais ne se déclenchaient jamais : OpenBao était créé AVANT que
      Kyverno n'applique. Le retard introduit par `foundation-vault dependsOn
      cert-manager` (prérequis du TLS) l'a fait passer sous contrôle d'admission.
      ⚠️ **Leçon** : l'ordre du DAG peut masquer une non-conformité réelle. Un
      composant qui « passe » n'est pas forcément conforme — il est peut-être
      juste arrivé avant le contrôle.
- [x] ~~**CA du TLS OpenBao au mauvais namespace**~~ — le `kustomization.yaml` de
      la brique vault porte `namespace: foundation-vault`, et le transformateur
      de Kustomize écrase le namespace de CHAQUE ressource. La CA atterrissait
      donc hors de `cert-manager`, seul endroit où un `ClusterIssuer` sait lire
      un `caBundleSecretRef`. Sortie dans `apps/base/foundation/vault-ca`.
      ⚠️ **Leçon de méthode** : non vu en local parce que le test y appliquait
      `tls.yaml` **directement** (`kubectl apply -f`), ce qui court-circuite la
      surcharge. **Valider un fichier n'est pas valider la brique** — en local,
      appliquer le DOSSIER (`kubectl apply -k`), jamais un fichier isolé.
- [x] ~~**Longhorn `backup-target` : API supprimée**~~ — Longhorn ≥ 1.6 a sorti
      la destination de sauvegarde des `Setting` pour une CRD `BackupTarget`
      dédiée ; le webhook rejette l'ancien nom (« setting backup-target is not
      supported »). J'avais vérifié le SCHÉMA du CRD `Setting` sans vérifier que
      `backup-target` était encore un nom supporté.
      ⚠️ **Leçon** : vérifier qu'un champ existe ne dit pas que la ressource est
      la bonne. Confronter le NOM de la ressource à la version déployée.

## SSO Grafana ↔ Zitadel — mesures réelles (2026-07-28)

Faites contre Zitadel **v4.14** sur le cluster OVH, via l'API (PAT `iam-admin`,
port-forward — la CNP bloque l'accès direct depuis un pod quelconque).

- ✅ **Les 4 endpoints configurés sont EXACTS**, confirmés par
  `/.well-known/openid-configuration` : `/oauth/v2/authorize`,
  `/oauth/v2/token`, `/oidc/v1/userinfo`, `/oidc/v1/end_session`.
- ❌ **Le scope de rôles manquait — défaut réel.** Avec `openid profile email`
  seul, `/oidc/v1/userinfo` ne contient **aucun** claim de rôles : tout le monde
  serait retombé sur `Viewer` en silence, quel que soit le `role_attribute_path`.
  Corrigé en ajoutant `urn:zitadel:iam:org:projects:roles`.
- ✅ **Structure du claim confirmée** : la valeur est un OBJET dont les clés sont
  les rôles — `{"grafana-admin": {"<orgId>": "<domaine>"}}`. `keys()` était donc
  la bonne approche.
- ⚠️ **Nom du claim : deux formes.** Mesuré `urn:zitadel:iam:org:project:<projectId>:roles`
  lorsqu'on demande les rôles de tous les projets. La forme NON préfixée vaut
  pour le projet auquel appartient le client (le cas de Grafana), mais cela n'a
  pas pu être reproduit sans un vrai flux navigateur. À trancher à la première
  connexion.
- Créé côté Zitadel : projet `OpenAether`, rôle `grafana-admin`, application web
  `Grafana` (code + PKCE, redirect `…/login/generic_oauth`),
  `projectRoleAssertion` activé. Identifiants seedés dans `secret/grafana/oidc`,
  ExternalSecret `SecretSynced`, variables injectées dans le pod Grafana.

## Backups / DR

- [x] ~~**Un dépôt restic par cluster (préfixe)**~~ → FAIT (2026-07-27),
      conception (a) retenue. Le chemin des dépôts devient
      `s3:<endpoint>/<bucket>/<CLUSTER_NAME>/{openbao,cnpg}`.

      Chaîne complète :
      - **parent** : `flux-bootstrap.yaml.tftpl` pose un ConfigMap
        `cluster-identity` (ns flux-system) avec
        `CLUSTER_NAME = <cluster>-<env>-<provider>` (le provider EN FAIT PARTIE :
        `openaether-dev` seul est identique sur les trois clouds, donc ne
        distingue rien) ;
      - **enfants** : `child-gitops` pose le même ConfigMap, valeur `${CHILD_NAME}`
        substituée par le management depuis `apps/clusters/edge-*.yaml` (le nom
        CAPI est déjà unique dans la flotte) ;
      - **briques `backup-*-identity`** (22a) recopient l'identité dans
        `foundation-vault` / `foundation-databases` ; les CronJobs la lisent via
        `envFrom.configMapRef`, au runtime.

      ⚠️ **Piège majeur évité** : mettre `postBuild.substituteFrom` directement
      sur les briques `backup-*` aurait vidé TOUTES les variables shell nues de
      leurs CronJobs (`$PRIMARY_ENDPOINT`, `$LEADER`, `$init_err`…) — la
      substitution Flux s'applique à l'intégralité du rendu d'une Kustomization.
      D'où deux Kustomizations dédiées qui ne rendent qu'un ConfigMap. **Ne
      jamais fusionner ces ressources dans `apps/base/backup/*`.**

      Le CronJob refuse de tourner si `CLUSTER_NAME` est vide, avec un message
      qui pointe la cause — plutôt qu'un `set -u` sec.

      **À valider au prochain déploiement** (non exerçable sans cluster) :
      substitution effective, et enfant à **18/18** (17 du profil + racine).
      ⚠️ Corollaire opérationnel inchangé : purger les préfixes d'un cluster
      détruit, ou son password escrowé devient la SEULE façon de relire ses
      backups. Les dépôts EXISTANTS (sans préfixe) restent en place : ils ne
      seront plus alimentés, à archiver ou supprimer sciemment.

- [x] ~~**Alerting échec backups**~~ → FAIT (2026-07-27) :
      `apps/base/observability/vm-customresources/vmrule-backup.yaml`, 3 règles.
      `BackupJobFailed` (Job en échec non repris, 15 min de grâce),
      **`BackupCronJobStale`** (aucun Job créé depuis > 26 h — le cas le plus
      dangereux, puisqu'il n'y a alors AUCUN échec à voir) et
      `BackupCronJobSuspended` (> 6 h, avertissement : suspendre est souvent
      volontaire, réactiver s'oublie).
      Placé dans `vm-customresources/` et pas dans `observability/` : le kind
      `VMRule` n'existe qu'après l'installation des CRDs par l'opérateur — même
      piège chicken-egg que VMCluster/VMAgent.
      ⚠️ Le PromQL n'a pas pu être vérifié par `promtool` (absent de la machine) :
      à confirmer au prochain déploiement.
- [x] ~~**Test de restauration périodique**~~ → FAIT (2026-07-27) : CronJob
      mensuel `restore-test-cronjob.yaml` dans CHACUNE des deux briques backup.
      Sur les 2 destinations : `restic check --read-data-subset=5%` (relit et
      DÉCHIFFRE réellement une fraction des données — ce que `restic check` seul
      ne fait pas) puis `restic restore latest` vers un `emptyDir` jetable, avec
      **assertion que le résultat n'est pas vide** : un restore « réussi » mais
      vide est un dépôt inexploitable.
      Les pods portent le label `app: <cronjob>` des CronJobs de sauvegarde —
      c'est lui que sélectionne la CiliumNetworkPolicy qui ouvre l'egress S3 ;
      sans ce label, aucun egress. Leurs Jobs matchent `BackupJobFailed`, donc
      un test raté alerte comme un backup raté.
      **À valider au prochain déploiement** (non exerçable sans cluster).
- [x] ~~**PITR CNPG**~~ → ACTIVÉ (2026-07-27) sur les deux bases (zitadel-db,
      grafana-db). `barmanObjectStore` archive les WAL en continu : le RPO passe
      de **24 h** (le seul filet était le `pg_dump` quotidien) à quelques minutes.
      - destination `s3://${BACKUP_S3_BUCKET}/cnpg/<base>`, substituée depuis
        `cluster-identity` ; credentials via ExternalSecret `cnpg-backup-s3`
        (même destination `backup/s3-primary` que restic et Longhorn) ;
      - **`ScheduledBackup` quotidiens ajoutés** : sans backup de base, les WAL
        archivés sont inexploitables — c'est le couple qui fait le PITR ;
      - rétention 30 j, compression gzip des WAL et des données.
      ⚠️ Le `schedule` de CNPG porte un champ SECONDES en tête (6 champs, format
      robfig/cron) — vérifié dans le CRD vendoré. À 5 champs, l'heure serait lue
      comme des minutes.
      La substitution est sûre sur cette brique : le manifeste vendoré de
      l'opérateur contient des `$(VAR_NAME)`, mais **vérifié — les 13 occurrences
      sont toutes dans des `description` de CRD**, aucune dans un conteneur.
      **À valider au prochain déploiement.**
- [x] ~~**Longhorn `backupTarget`**~~ → CÂBLÉ (2026-07-27). Les volumes n'avaient
      **aucune** destination de sauvegarde : `backupTarget: ""` renvoyait à un
      « overlay cloud » qui n'a jamais existé. Désormais :
      - `apps/base/storage/backup-target/` : `ExternalSecret`
        `longhorn-backup-credentials` (les 3 clés qu'attend Longhorn —
        `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS` — depuis
        `secret/backup/s3-primary`, la même destination que les dépôts restic) +
        deux `Setting` CR (`backup-target`, `backup-target-credential-secret`) ;
      - l'URL vient du ConfigMap `cluster-identity`, OpenTofu l'assemblant au
        format `s3://<bucket>@<region>/` (`backup.tf`, `local.backup_data_bucket`).
        Assemblée côté tofu parce que la substitution Flux ne sait pas concaténer
        conditionnellement.
      - Kustomization `21c` **séparée** de `storage` : elle porte le
        `substituteFrom`, et la substitution s'applique à tout le rendu — fusionnée,
        elle viderait `$VOL_DIR` dans `install.yaml`. Même piège que les backups.
      - Setting CR et non `defaultSettings` du chart : ce dernier n'est lu qu'au
        premier déploiement, les CR survivent aux upgrades.
      Forme du CRD **vérifiée** contre Longhorn v1.9.2 (`longhorn.io/v1beta2`,
      `value` à la racine). Défaut vide si le cluster ne publie pas l'URL — les
      enfants CAPI, qui ne piochent pas `storage`, gardent le comportement actuel.
      Les volumes étant LUKS, les backups sont chiffrés par construction.
      **À valider au prochain déploiement.**
- [x] ~~**etcd-snapshot planifié**~~ → FAIT (2026-07-27) :
      `scripts/ops/etcd-snapshot-cron.sh <provider> [clé]`, ligne de crontab
      documentée dans `docs/admin-access.md` § 3ter.
      La task seule n'était pas utilisable en cron, pour quatre raisons — toutes
      traitées par le wrapper : `PATH` minimal de cron alors que les outils sont
      éparpillés (`/usr/local/bin` et `/snap/bin`) ; credentials absents de
      l'environnement de cron ; **`task etcd-snapshot` ouvre les tunnels SSH et
      ne les referme jamais** (voulu en interactif, mais ils s'accumuleraient en
      cron) ; et aucun garde-fou contre le recouvrement de deux exécutions.
      Vérifié en réel avec `PATH=/usr/bin:/bin` : le wrapper retrouve ses outils,
      source l'environnement, atteint le backend distant, puis échoue proprement
      sur l'absence d'infrastructure — trap déclenché, code non nul, message
      horodaté.

## Observabilité / diagnostic

- [x] ~~**`cilium-dbg status` « Cluster health » structurellement faux**~~ →
      corrigé (2026-07-27) par `apps/base/platform/network-policies/allow-cilium-health.yaml`.
      `default-deny-all-ingress` porte `endpointSelector: {}` : il couvrait donc
      aussi les endpoints spéciaux `cilium-health` (un par nœud), dont les sondes
      ICMP + TCP 4240 étaient droppées. Tous les clusters OpenAether affichaient
      donc **1/N reachable en permanence**, chaque nœud ne voyant que le sien.
      **Ce n'était pas cosmétique** : ce faux signal a fait conclure le
      2026-07-26 que le datapath inter-nœuds d'edge-2 était « définitivement
      cassé » et a motivé sa mise au rebut. Vérifié le 2026-07-27 : le management
      (32/32, 6 nœuds Ready) affichait le même 1/6 pendant que le pod-à-pod
      inter-nœuds fonctionnait (DNS résolu depuis un worker vers les CoreDNS du
      control plane). Après correctif : management **6/6**, edge-2 **2/2**.
      **Leçon de méthode** : avant de conclure au datapath cassé sur ce signal,
      le comparer à un cluster sain — et le confirmer par un test de trafic réel
      (DNS cross-nœud, `kubectl exec`), pas par la sonde seule.

## Multi-provider / infra

- [x] ~~**OVH : port du bastion sans `fixed_ip` → apply intermittent**~~ → corrigé
      (2026-07-27). `openstack_networking_port_v2.bastion` ne déclarait que
      `network_id`, ce qui ne crée **aucune dépendance vers le subnet** :
      OpenTofu pouvait créer le port avant lui et Neutron le laissait sans IPv4.
      L'apply cassait alors bien plus loin, sur deux messages qui ne désignent
      pas la cause : « Port <id> requires a FixedIP in order to be used » (boot
      du bastion) et « Cannot add floating IP to port <id> that has no fixed
      IPv4 addresses ». **C'est une course** : plusieurs déploiements OVH sont
      passés sans. Les ports des control planes et le VIP déclaraient déjà leur
      `fixed_ip` — le bastion était le seul en écart. **Leçon générale** : sur
      Neutron, un port dont on attend une IP doit toujours porter un bloc
      `fixed_ip { subnet_id = … }`, autant pour l'ordre que pour l'allocation.

- [ ] **OVH : un nœud peut rester `ACTIVE` côté hyperviseur tout en étant mort**
      (2026-07-27, `openaether-dev-cp-0`). Symptôme : `Kubelet stopped posting
      node status`, pods statiques en `Terminating`, et l'API **Talos elle-même**
      qui reset la connexion (`apid` muet) alors que `cp-1`/`cp-2` répondent par
      les mêmes tunnels. Diagnostic par la **console série Nova**
      (`os-getConsoleOutput`) : le `init` Talos a appelé `reboot()`
      (`__se_sys_reboot` → `kernel_restart`) et le noyau s'est **bloqué dans
      l'arrêt des périphériques** — `device_shutdown` → `vp_reset [virtio_pci]`
      — avec `rcu: INFO: rcu_preempt self-detected stall on CPU 0` en boucle
      dans `virtnet_poll`. La VM ne termine jamais son redémarrage.
      `os-instance-actions` ne liste que le `create` : le reboot vient **de
      l'intérieur**, ce n'est pas une action plateforme.
      Reprise : `reboot` type `HARD` via l'API Nova (le reset ACPI ne sert à
      rien, l'invité est déjà coincé dans son propre reboot).
      À creuser : **pourquoi Talos a-t-il demandé ce reboot** (aucun apply de
      config en cours à ce moment) ; hang connu noyau 6.18/virtio au shutdown ?
      **Méthode à retenir** : quand `talosctl` reset la connexion sur UN nœud et
      répond sur les autres, passer directement à la console série du provider —
      c'est le seul canal qui reste quand apid est mort.

- [x] ~~**OVH : associations de floating IP sans `depends_on` sur le routeur**~~ →
      corrigé (2026-07-28), trouvé au **premier apply** du run de validation.
      Neutron REFUSE d'associer une FIP tant que le subnet du port n'a pas de
      route vers le réseau externe :
      `ExternalGatewayForFloatingIPNotFound: External network <id> is not
      reachable from subnet <id>`. Aucune référence ne liait
      `openstack_networking_floatingip_associate_v2` à
      `openstack_networking_router_interface_v2` → création en PARALLÈLE, donc
      **échec intermittent** selon qui gagne la course.
      **Les TROIS associations** du module étaient concernées (bastion, LB k8s,
      LB app) ; seul le bastion a perdu la course, les deux LB passant par
      chance — un load balancer est plus lent à créer. Les trois ont été
      corrigées, pas seulement celle qui a échoué.
      **Suite directe du correctif `fixed_ip` de la veille** : celui-ci a
      supprimé la première course et a ainsi révélé la seconde. Leçon : sur
      Neutron, une ressource qui dépend d'un chemin réseau doit le déclarer —
      `network_id` ou un simple `port_id` ne suffisent pas à ordonner.

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
      (b) et (c) FAITS (2026-07-27) : `task preflight-quotas PROVIDER=…`
      (`scripts/ops/preflight-quotas.py`, lecture seule) affiche quotas et
      consommation réels et **simule** une topologie (`--add-vms/--add-cores/
      --add-ram-gb`), en sortant en erreur si elle dépasse. Vérifié sur les deux
      comptes : il rejette bien le management HA Outscale (44 Go pour 40) et
      valide la topologie OVH réellement déployée (9/10 instances). Les quotas
      des trois providers sont tabulés dans `docs/admin-access.md` § 3bis.
      Reste (a), décision de l'opérateur : demander une hausse de quota chez
      Outscale si l'on veut la flotte complète (management HA + enfant).

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
- [x] ~~**FIP des CP OpenStack créée hors CAPI**~~ → pré-création **scriptée et
      idempotente** (2026-07-27) : `scripts/ops/ensure-capo-fip.py <enfant>`
      retrouve la FIP à sa description (`openaether:<cluster>`), n'en alloue une
      que s'il n'y en a pas, et imprime l'adresse à reporter dans
      `OS_CP_FLOATING_IPS`. Relançable sans créer de doublon facturé.
      Reste **volontairement** un report manuel d'une ligne : l'IP doit entrer
      dans les `certSANs` Talos, donc en git, avant le boot. ⚠️ Le pool utilise
      `reclaimPolicy: Retain` — le passer à `Delete` ferait **détruire l'IP** à
      la suppression du pool, et le certSAN en git deviendrait faux.
      Ne restent à automatiser que si on veut zéro geste : un `tofu` dédié aux
      ressources « pré-CAPI » d'un enfant.
- [~] **`talos_cluster_health` expire sur cluster SAIN — DÉFAUT GÉNÉRIQUE** :
      reproduit à l'identique sur **OVH puis Outscale** (3 CP + 3 workers, tous
      Ready, etcd HEALTH OK sur les 3 CP, DAG Flux complet). Ni un problème de
      durée (15 min) ni un particularisme provider ; la piste SG est écartée
      (règle inter-node = tout le trafic intra-SG). Non observé sur les
      management Scaleway. Contournement : `skip_health_check` (activé dans
      management-{ovh,outscale}.tfvars).

      **Le DÉGÂT est corrigé (2026-07-27)** : `talos_cluster_kubeconfig` ne
      dépend plus du health check. Il le gardait, si bien qu'une expiration
      faisait échouer l'apply AVANT les outputs — on perdait kubeconfig ET
      talosconfig, plus le backup des artefacts, sur un cluster sain. Découplés,
      le health check fait toujours échouer l'apply (le signal reste), mais le
      kubeconfig est en state : `task kubeconfig` marche et
      `task bootstrap-phase2` reprend. Cette entrée fusionne l'ancien doublon
      « timeout trop court en HA multi-AZ » (même défaut, hypothèse invalidée).
      Le timeout est par ailleurs déjà paramétrable (`health_check_timeout`,
      défaut 15 min).

      **Reste ouvert, en amont** : le bump du provider `siderolabs/talos` n'est
      PAS possible — vérifié le 2026-07-27 auprès du registry, la ligne 0.12.x
      n'a que des pre-releases (jusqu'à `0.12.0-alpha.5`), 0.11.0 reste la
      dernière stable. Donc : soit attendre 0.12.0 stable, soit ouvrir l'issue
      upstream avec les traces des deux reproductions.
- [ ] **Proxmox** : premier apply réel (SYS-1) + hardening Ansible hôte (absent
      du repo, seulement documenté).
- [x] ~~**Ingress public** : trancher CCM vs LB-IPAM~~ → TRANCHÉ et raccordé
      (2026-07-27). **Ce n'étaient pas deux solutions au même problème** : le CCM
      provisionne un LB cloud à partir d'un `Service type=LoadBalancer` ;
      LB-IPAM attribue l'IP que porte le Service DANS le cluster. Le pool est
      privé (172.16.12.240-254), donc LB-IPAM ne produit aucune IP publique, et
      l'IP publique vient déjà d'un LB créé par **OpenTofu** — pas du CCM.

      **Décision : LB-IPAM dedans, LB public dans OpenTofu, pas de CCM.** Le CCM
      ferait remonter des annotations spécifiques au provider dans la couche
      `apps`, qui est justement la couche partagée que l'architecture garde
      agnostique (les spécificités vivent dans `modules/providers/`) ; et il
      n'existe pas sur Proxmox, qui est dans le périmètre. En prime, un
      composant de moins portant des credentials cloud dans le cluster.

      **Raccordement livré** — le chemin public était cassé parce que le LB
      ciblait `worker:80/443` où rien n'écoute :
      - `apps/base/services-gateway/service-nodeport.yaml` : Service NodePort
        dédié, ports **FIGÉS 30080/30443**, sélectionnant les pods du Gateway.
        Figés parce que le LB est créé en PHASE 1, avant le cluster : il ne peut
        pas découvrir un nodePort alloué au hasard (30000-32767).
      - `app_lb_node_ports` dans les 3 modules provider (scw/ovh/outscale) :
        backends du LB **et règles de security group** repointés dessus. Ouvrir
        80/443 sur les nœuds n'aurait servi à rien.
      - CNP `openaether-gateway` élargie aux entités `host`/`remote-node` : en
        `externalTrafficPolicy: Cluster`, le nœud SNAT le paquet, donc Cilium ne
        voit plus `world` mais le nœud — sans ça tout l'ingress public est droppé.

      ⚠️ **Contrat inter-dépôts** : les numéros de port sont dupliqués des deux
      côtés, chaque fichier pointant sur l'autre. Un écart = LB qui pointe dans
      le vide, sans erreur nulle part.

      Le Service LoadBalancer d'Istio et sa VIP privée sont **inchangés** : le
      chemin d'administration par tunnel SSH n'est pas touché.
      **À valider au prochain déploiement** (non exerçable sans cluster).
      Le CCM redeviendrait le bon choix si Proxmox sortait du périmètre, ou pour
      des LB publics à la demande par application.
- [x] ~~**Observability S3 cloud**~~ → CÂBLÉ (2026-07-27). Loki lisait
      `minio/root` : en cloud ses logs atterrissaient sur le MinIO interne, donc
      sur des volumes Longhorn — ce qui annule l'intérêt d'un stockage objet.
      Désormais **credentials ET emplacement** (endpoint + bucket) transitent par
      le Secret `loki-s3-credentials`, injectés en `valuesFrom` : passer du MinIO
      interne au S3 du provider ne demande **aucun changement de code**, seulement
      un reseed d'`observability/loki-s3`.
      Destination volontairement **distincte de `backup/s3-primary`** : réutiliser
      celle-ci donnerait à Loki un accès en écriture au bucket des sauvegardes —
      un Loki compromis pourrait les effacer.
      Pas de substitution Flux sur cette brique : les dashboards Grafana
      contiennent des `${datasource}` qui seraient vidés.
      ⚠️ Reste à faire au câblage cloud réel : `rules.dns` sur la CNP `toFQDNs`
      de Loki (le proxy DNS Cilium, sans quoi les toFQDNs ne matchent jamais).
      **À valider au prochain déploiement.**
- [x] ~~**`test-local-stack.sh` / fmt**~~ → réglé (2026-07-27). Deux moitiés :
      `infrastructure/.yamllint` **existe** aujourd'hui (l'entrée était périmée) ;
      et `tofu fmt -recursive infrastructure/opentofu` embarquait le dossier de
      travail local `_v2/`, faisant échouer `task lint` sur `_v2/_test.tfvars`.
      `lint`/`fmt` énumèrent désormais les racines réelles (`cluster`, `modules`,
      `talos-image`, `opentofu-local`) — **ajouter ici toute nouvelle racine**.
      `task lint` passe intégralement.
      Reste, pour l'opérateur : `infrastructure/opentofu/_v2/` est un scratch non
      suivi (22 juin) — à supprimer s'il ne sert plus. Non touché ici : ce sont
      des fichiers locaux.
- [ ] **kyverno background-controller** : entrée à REQUALIFIER — vérifié le
      2026-07-27, **rien ne le désactive côté configuration**. Le rendu de
      `apps/base/kyverno` produit bien les 4 Deployments (admission, background,
      cleanup, reports) sans surcharge de `replicas`, et toutes les ClusterPolicy
      portent `background: true`. L'entrée décrit donc un état d'EXÉCUTION
      constaté, pas un choix de config.
      → À reprendre au prochain déploiement : le Deployment
      `kyverno-background-controller` tourne-t-il, et des `ClusterPolicyReport`
      sont-ils produits ? Si non, chercher côté crash/RBAC/ressources, pas côté
      manifests.

- [x] ~~**Kyverno installé depuis une URL GitHub distante**~~ → VENDORÉ
      (2026-07-27) : `apps/base/kyverno/kyverno-1.12.1.yaml` (3,1 Mo), avec URL
      d'origine et **sha256** en commentaire, plus la marche à suivre pour monter
      de version. La réconciliation Flux ne dépend plus de la disponibilité de
      GitHub, le rendu est reproductible hors ligne, et le contenu est figé (pas
      seulement la version).
      Aligné sur le précédent du dépôt : `cnpg-1.23.1.yaml` était déjà vendoré
      pour cette raison (« évite fetch remote (DNS/IPv6) »), comme `cilium.yaml`
      et `flux-install.yaml` côté infra.
      **Rendu vérifié IDENTIQUE à l'octet près** avant et après bascule
      (3 179 903 octets). Balayage fait : plus AUCUNE base distante dans les deux
      dépôts.

## Reproductibilité des artefacts générés

- [x] **`bootstrap-manifests/cilium*.yaml` avaient divergé de leur générateur** —
      les deux artefacts portaient `cni-exclusive=false`, `bpf-lb-sock-hostns-only=true`
      et `nodeSelectorLabels=true` (édités à la main lors d'un debug ambient),
      valeurs que `render-bootstrap-manifests.sh` ne passait pas : régénérer
      cassait Istio ambient en silence. Les `--set` sont désormais dans le script,
      avec la raison. *(corrigé 2026-07-26)*
- [x] ~~**Test de non-régression du rendu**~~ → FAIT (2026-07-27) :
      `task render-check` (= `render-bootstrap-manifests.sh --check`) rejoue le
      rendu dans un dossier jetable et compare, sans rien écrire. Il normalise
      les espaces de fin de ligne des DEUX côtés, sinon il serait rouge en
      permanence : l'artefact committé passe par le hook pre-commit
      `trim trailing whitespace`, pas le rendu brut de helm.

      **La cause racine de toute cette classe de bugs a été trouvée au passage :
      le script écrivait dans un répertoire FANTÔME.** Il vit dans
      `scripts/bootstrap/` mais calculait sa sortie avec `${SCRIPT_DIR}/../infrastructure/…`
      soit `scripts/infrastructure/…`, créé à la volée par son propre `mkdir -p`
      et jamais lu par OpenTofu. `task render-manifests` semblait donc marcher
      tout en ne régénérant **jamais** les artefacts committés — d'où leur
      dérive, et d'où le fait que des `--set` aient dû être ajoutés à la main
      dans les artefacts. Corrigé en `../../`.

      Le contrôle a immédiatement payé : il a attrapé que le mode **local** du
      générateur oubliait `socketLB.enabled=true`, présent lui dans l'artefact
      (avec son commentaire d'origine). Régénérer aurait produit
      `bpf-lb-sock: "false"`, rendant `bpf-lb-sock-hostns-only` inopérant et
      recassant l'accès des pods hostNetwork aux ClusterIP. Le `--set` a été
      remis dans le script ; artefacts et générateur sont désormais alignés
      (vérifié clé par clé sur le ConfigMap : 147 clés identiques, 0 valeur
      divergente).

      Reste : **épingler `FLUX_VERSION`** — il est vide, donc `latest`, ce qui
      rend `flux-install.yaml` non reproductible et exclu du contrôle.
- [x] **Profils `pick.py` périmables en silence** : un profil fige la liste des
      Kustomizations *exclues*, donc toute brique ajoutée au DAG est héritée de
      `../base` sans avoir été pioché (vécu : `orc` bloqué sur les edges).
      `pick.py --check` + `task apps-validate` détectent le drift. *(2026-07-26)*

## Dette de process

- [x] ~~Merge `feat/pioche-backup-gitception` → main~~ → FAIT (2026-07-27) :
      une seule branche `main` dans les deux dépôts, `git_branch="main"` côté
      `cluster/main.tf`, plus aucun `CHILD_BRANCH` dans `apps/clusters/`.
- [x] ~~CHANGELOG apps inexistant~~ → FAIT (2026-07-27) :
      `OpenAether-apps/CHANGELOG.md`, démarré à cette date. Les 200 commits
      antérieurs ne sont pas rétro-documentés — l'historique git fait foi, et le
      « pourquoi » des décisions vit ici, dans ce backlog.
