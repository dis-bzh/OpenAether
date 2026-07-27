# Backlog — améliorations identifiées (source de vérité)

Tout ce qui a été identifié comme **mieux que l'existant**, avec le pourquoi.
Alimenté au fil des sessions (humain + assistant). Retirer les entrées faites.

## Où on en est (mis à jour le 2026-07-27, fin de session)

**Aucune infrastructure cloud ne tourne.** `task fleet-down PROVIDER=ovh` a
détruit les deux enfants CAPI en cascade puis 80 ressources OpenTofu. Vérifié à
zéro : **OVH** (0 serveur, 0 FIP — l'IP pré-allouée d'edge-2 a été purgée via
`purge-orphans/ovh.py --apply`), **Scaleway** (0 serveur / volume / IP / LB sur
fr-par-1/2/3) et **Outscale** (aucun orphelin). Tunnels SSH fermés, kubeconfigs
des enfants supprimés. `restic-escrow-OUTSCALE.txt` **conservé volontairement**
— il déverrouille les dépôts restic restés en bucket.

Ce run a **validé les quatre points restants** — et fait tomber **cinq défauts
réels** au passage (tous corrigés et poussés, cf. sections dédiées) :

1. **Enfant neuf 17/17 : VALIDÉ.** edge-2 créé from scratch atteignait 17/17 avec
   les values corrigées. `istio-cni-node` est `1/1 Running` sur les deux nœuds —
   c'est exactement ce qui restait bloqué 3 h le 2026-07-26.
2. **`apiserver → kubelet:10250` : RÉSOLU.** `kubectl logs` et `kubectl exec`
   fonctionnent sur l'enfant OVH. Aucune règle de security group n'était en
   cause : c'était bien `ipam.mode` manquant (le pool `cluster-pool` par défaut
   taillait les pods dans `10.0.0.0/8`, où vit le subnet des nœuds).
3. **Asymétrie `socketLB.hostNamespaceOnly` : elle n'existait pas.** Preuve
   directe — avec `hostNamespaceOnly=true` sur l'enfant, `cert-manager-issuers`
   et `external-secrets-stores` (les deux Kustomizations qui échouaient en
   « failed calling webhook ») sont `True`.
4. **Une seule branche `main`** dans les deux dépôts.

Puis, sur demande, **edge-1 (Scaleway) a été recréé et validé à 17/17** (18 depuis l'ajout de la brique d'identité backup) — le
correctif `ipam.mode` tient donc sur **deux providers aux topologies opposées** :
nœuds en IP publique côté Scaleway (hors `10.0.0.0/8`), en `10.20.0.0/24` côté
OpenStack (dedans). Au passage, un management OVH pilotant un enfant Scaleway :
la kubeception **cross-provider** est exercée pour de vrai.

Ce qui est **validé en cloud réel** :

- Le socle est **provider-agnostique pour de vrai** : le même code a porté un
  management sur **Scaleway, OVH et Outscale**, chaque provider ayant révélé
  (puis fait corriger) des défauts propres.
- **Kubeception/gitception validée de bout en bout**, y compris la reprise :
  l'enfant a traversé trois correctifs poussés en cours de route sans
  intervention manuelle, par simple reconvergence Flux.
- **Backups** restic chiffrés client, multi-destination et **cross-provider**,
  validés dans les trois sens (non re-seedés sur ce run : inutile pour l'objet
  du test, et les briques `backup-*` passent `True` sans le seed).
- **Pioche modulaire** (`scripts/pick.py`) : fermeture transitive, profils
  générés, garde-fous `--check` + parité Cilium socle/enfants.
- **Résilience** : reboot simultané non sollicité des 6 VMs Outscale
  (2026-07-26) — le cluster est revenu seul.

Ressources conservées entre les runs (les détruire coûte du temps ou de la
restaurabilité) : buckets S3 (tfstates, artefacts, **dépôts restic**) et images
Talos v1.13.4 sur les 3 clouds. ⚠️ Les dépôts restic survivent aux clusters,
**pas leur `RESTIC_PASSWORD`** — `infrastructure/opentofu/cluster/restic-escrow-OUTSCALE.txt`
est conservé volontairement, il déverrouille les dépôts restés en bucket.

Créés hors OpenTofu, donc à recréer après un teardown : keypair Outscale
`openaether-capi`, et la **FIP OVH d'un enfant OpenStack** — désormais
idempotente via `scripts/ops/ensure-capo-fip.py <enfant>` (reporter l'adresse
dans `OS_CP_FLOATING_IPS`).

Ce qui **reste ouvert** :

1. **Mutation à chaud du CNI d'un enfant** : toujours déconseillée (elle a
   dégradé deux enfants le 2026-07-26). Recréer reste la voie sûre. Ce run n'a
   pas re-testé la mutation, seulement la création.
2. **Durcir les enfants** : `network.controlPlaneLoadBalancer` (endpoint = IP
   publique du CP aujourd'hui, non-HA), private network / gateway.
3. **Pourquoi Talos a-t-il demandé un reboot sur `cp-0`** (aucun apply en cours,
   aucune action plateforme côté API OVH) — cf. section Multi-provider.

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
- [x] ~~**Teardown d'un enfant annulé en boucle par Flux**~~ → corrigé
      (2026-07-27). `edge-down` supprimait le `Cluster`, mais la Kustomization
      `<cluster>-cluster` le **recréait** avant que la cascade CAPI n'ait
      démarré : les Machines n'obtenaient jamais de `deletionTimestamp` et le
      script bouclait jusqu'au timeout **sans rien signaler**, le `kubectl
      delete` étant redirigé vers `/dev/null`. `edge-down.sh` suspend désormais
      `<cluster>-cluster` **et** `capi-clusters` avant de supprimer, et sort
      immédiatement si le delete est refusé. **Leçon** : sous GitOps, toute
      suppression d'objet réconcilié doit commencer par suspendre sa source —
      et un `delete` dont on jette la sortie transforme un refus en attente
      silencieuse.
- [x] ~~**`kubectl get/delete cluster` ambigu**~~ → corrigé (2026-07-27) : le
      kind `Cluster` est aussi celui de CNPG (`postgresql.cnpg.io`). Sans CRDs
      CAPI installées — management partiellement détruit, providers pas encore
      réconciliés — `kubectl get cluster -A` retourne **les bases de données**
      (constaté : `grafana-db`, `zitadel-db`). `fleet-down` les aurait alors
      énumérées comme enfants à détruire, et `edge-down` aurait pu en supprimer
      une. Tous les appels sont désormais qualifiés `clusters.cluster.x-k8s.io`.
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
- [x] ~~`socketLB.hostNamespaceOnly` : parent=true, enfants=false~~ → l'asymétrie
      **n'existait pas** (analysé le 2026-07-27). La doc du chart tranche :
      *« Disable socket lb for non-root ns »* — le flag ne coupe le socket-LB que
      pour les netns **non-root**. `kube-apiserver` est host-network, donc en
      netns racine : il garde la traduction ClusterIP dans les deux réglages, et
      ne peut pas être cassé par ce flag. Le « failed calling webhook » du
      2026-07-26 a été observé **pendant** le rollout de CNI à chaud qui avait
      déjà détruit le datapath des enfants — imputation erronée. Les enfants sont
      repassés à `true`, aligné sur le socle et exigé par Istio ambient.
      **Vraie cause de fond trouvée au passage : `ipam.mode` manquant** (entrée
      ci-dessous).
- [x] ~~Vérifier l'alignement parent/enfant automatiquement~~ → FAIT
      (2026-07-27) : `scripts/ops/check-cilium-parity.py`, câblé dans
      `task apps-validate`. Il compare 14 réglages structurants entre le bloc
      production de `render-bootstrap-manifests.sh` et chaque HelmRelease
      `*-cilium` des enfants ; une clé **absente** côté enfant est signalée
      (elle prend le défaut du chart, qui diffère). Les écarts voulus se
      déclarent dans `EXCEPTIONS` avec leur justification. Vérifié : il détecte
      bien les deux défauts réels de la veille.
- [x] ~~**Enfants CAPI : `ipam.mode` manquant** — LA dérive coûteuse~~ → corrigé
      (2026-07-27). Les trois `apps/clusters/edge-*.yaml` ne posaient pas
      `ipam.mode`, contrairement au socle parent *et* au fichier d'exemple
      `example-scaleway.yaml.example` (qui l'avait, preuve de la dérive). Le
      défaut du chart est `cluster-pool` : Cilium **ignore alors le
      `clusterNetwork.pods` déclaré par CAPI** (10.244.0.0/16) et taille les CIDR
      de pods dans `10.0.0.0/8` — le /8 où vivent justement les sous-réseaux de
      nœuds (OpenStack 10.20.0.0/24, edge-3 10.30.0.0/16, et 10.0.0.0/24 pour
      OVH/Outscale/Proxmox côté socle). Le parent pose `ipam.mode=kubernetes`
      pour exactement cette raison : son propre subnet est `10.0.0.0/24`, soit le
      **premier /24 distribué par le pool**. Explique la corrélation observée :
      edge-1 (Scaleway, nœuds en IP publique, **hors** du /8) tenait à 11/17,
      edge-2 (OpenStack, nœuds **dans** le /8) était à 0/17 avec le datapath
      inter-nœuds mort. Piste sérieuse aussi pour le `kubelet:10250` ci-dessous.
      **CONFIRMÉ sur edge-2 neuf le 2026-07-27** : `ipam=kubernetes`, nœuds en
      `10.20.0.x`, pods réellement en `10.244.x`, `kubectl logs`/`exec`
      fonctionnels, 17/17.
- [x] ~~**HelmRepository `cilium` enfermée dans edge-1.yaml**~~ → corrigé
      (2026-07-27). La source de chart est PARTAGÉE par tous les enfants mais
      était déclarée dans le fichier de l'un d'eux : désactiver edge-1 dans
      `kustomization.yaml` privait edge-2 de son CNI (« HelmRepository "cilium"
      not found », nœuds NotReady indéfiniment). Sortie dans
      `apps/clusters/helmrepository-cilium.yaml`. **Leçon** : une ressource
      partagée par N enfants n'a rien à faire dans le fichier de l'un d'eux —
      le couplage reste invisible tant que le premier enfant est activé.
- [x] ~~**AuthorizationPolicies `foundation-storage` non décomposables**~~ →
      corrigé (2026-07-27). `apps/base/istio/authz` est appliqué dès qu'Istio est
      pioché, mais contenait deux policies visant `foundation-storage` —
      namespace créé par la brique `storage`. Tout profil « istio sans storage »
      (le profil `workload` des enfants !) bloquait sur « namespaces
      "foundation-storage" not found » : edge-2 est resté à 16/17. Scindées dans
      la brique compagnon `istio-authorizationpolicies-storage`
      (`dependsOn: [istio-authorizationpolicies, storage]`).
      **Règle générale à retenir** : une policy qui protège une brique
      optionnelle doit suivre le sort de cette brique, sinon elle casse
      l'invariant de décomposabilité du DAG. `pick.py --validate` ne peut pas
      l'attraper : il valide les `dependsOn`, pas les références de namespace
      à l'intérieur des manifests.
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
- [x] ~~**edge-2/OVH : `apiserver → kubelet:10250` en timeout**~~ → RÉSOLU et
      vérifié (2026-07-27). Sur un edge-2 recréé avec `ipam.mode=kubernetes`,
      `kubectl logs` et `kubectl exec` fonctionnent. Les security groups CAPO
      n'étaient pas en cause : en `cluster-pool`, Cilium tenait `10.0.0.0/8`
      pour l'espace de pods du cluster, or le subnet des nœuds (`10.20.0.0/24`)
      est DEDANS. Confirmé par la topologie : edge-1 (Scaleway, nœuds en IP
      publique, hors du /8) n'a jamais eu le symptôme.
      **Leçon de méthode** : le symptôme désignait le réseau du provider, la
      cause était dans les values du CNI. Vérifier l'IPAM avant les SG.
- [x] ~~Deux branches à garder synchro~~ → FAIT (2026-07-27) : plus qu'une
      branche, `main`, dans les deux dépôts. Les `CHILD_BRANCH` des
      `apps/clusters/*.yaml` ont été retirés (défaut `${CHILD_BRANCH:=main}`).
      **Leçon** : la branche de test avait été supprimée côté git *sans* que les
      overrides le soient — un enfant créé dans cet état aurait suivi une source
      introuvable. Ne surcharger `CHILD_BRANCH` que le temps d'un test, et le
      retirer avec la branche.
- [ ] **Enfants durcis** : `network.controlPlaneLoadBalancer` (aujourd'hui
      endpoint = IP publique du CP, non-HA) + private network / gateway au lieu
      d'une IPv4 publique par nœud.
- [~] **Rate-limit GitHub de l'operator CAPI** : mécanisme **vérifié et
      documenté** (2026-07-27) en tête de
      `apps/base/cluster-api-providers/core-providers.yaml`, mais **non activé**.
      L'API a été confrontée au schéma réel de la CRD
      `operator.cluster.x-k8s.io/v1alpha2` : `configSecret` (token GitHub, slot
      libre — aucun provider ne l'utilise) et `fetchConfig.oci` (miroir).
      Non activé volontairement : le token est un secret propre à l'opérateur et
      **un `configSecret` pointant un Secret absent casse le provider**. Reste à
      faire, côté opérateur : créer le Secret puis décommenter le bloc.
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
- [x] ~~**Moderniser le template Scaleway**~~ → entrée PÉRIMÉE, vérifiée le
      2026-07-27 : les **trois** templates sont déjà en `cluster.x-k8s.io/v1beta2`
      avec des refs `{apiGroup, kind, name}`. Les `v1alpha2`/`v1alpha3` restants
      sont les CRD **propres à chaque provider** (CAPS v1alpha2, CABPT/CACPPT
      v1alpha3) — leur version courante, pas de la dette.
- [x] ~~**Longhorn/iscsi sur les enfants**~~ → entrée PÉRIMÉE, vérifiée le
      2026-07-27 : `talos-image/schematic.yaml` contient bien `iscsi-tools` ET
      `util-linux-tools`, et il résout en `53513e54bb39…` — exactement l'ID
      enregistré pour les images v1.13.4 des trois clouds. Les images publiées
      embarquent donc les extensions.
      Méthode de vérification (rejouable) : `curl -X POST
      https://factory.talos.dev/schematics --data-binary @schematic.yaml` → l'ID
      est déterministe, même contenu = même ID.
      Reste non exercé : piocher réellement `storage` sur un enfant.

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
- [ ] **PITR CNPG** : activer `barmanObjectStore` en overlay cloud (RPO actuel
      = dump quotidien, 24 h).
- [ ] **Longhorn `backupTarget`** par environnement (Setting non câblé ; volumes
      LUKS → backups chiffrés par construction).
- [ ] **etcd-snapshot planifié** : cron côté opérateur (la task existe, rien ne
      la déclenche périodiquement).

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
- [ ] **kyverno background-controller** désactivé (reports cluster absents).

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
- [ ] CHANGELOG apps inexistant (l'infra en a un).
