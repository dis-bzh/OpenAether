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

- [x] ~~**Tokens OpenBao nominatifs**~~ → FAIT (2026-07-27). Deux policies
      créées par le Job de bootstrap : `openaether-admin` (exploitation courante)
      et `openaether-reader` (lecture seule, audit/astreinte). Procédure
      `bao token create -policy=… -ttl=8h -display-name=<prénom>` documentée dans
      `docs/admin-access.md` § 4.
      `openaether-admin` **refuse explicitement** `sys/seal`, `sys/step-down`,
      `sys/rekey/*` et `sys/rotate` — écrits en `deny` plutôt qu'omis, pour que
      l'intention soit lisible dans la policy et qu'un élargissement futur de
      `sys/*` ne les rouvre pas par accident. Ces gestes de dernier recours
      restent au root token escrowé hors ligne.
      ⚠️ DEUX pièges, dont un que seule l'exécution réelle a révélé :
      (a) les policies sont écrites en `printf` une-ligne, pas en heredoc — un
      heredoc s'indente à la colonne 0 et **sort du scalaire YAML** du script ;
      (b) les continuations de ligne s'écrivaient `\\` au lieu de `\` : bash
      prenait le backslash pour un argument littéral, l'appel partait **sans
      token** (« permission denied ») et le JSON de la policy était exécuté comme
      une commande. **`bash -n` ne peut pas l'attraper** — `\\` + saut de ligne
      est syntaxiquement valide. Trouvé en déployant pour de vrai.

      **VALIDÉ sur cluster Talos local** (3 CP + 3 workers, `task local-test`) :
      `policy openaether-admin: HTTP=204`, `policy openaether-reader: HTTP=204`,
      puis test d'acceptation depuis l'intérieur du cluster —
      admin : `sys/mounts` 200, écriture secret 200, **`sys/seal` 403**,
      **`sys/step-down` 403** ; reader : lecture 200, **écriture 403**.
      (`sys/rekey/init` renvoie 405 : l'opération n'a pas lieu, mais rien ne
      prouve que ce soit la policy qui la bloque.)
      Suite naturelle : auth OIDC via Zitadel, pour des identités fédérées plutôt
      que des tokens créés à la main.
- [ ] **Wave 3 unsealer** : escrow direct Bitwarden EU des parts Shamir,
      suppression du Secret etcd `openbao-recovery` (TODO déjà tracé dans
      `unsealer.yaml` + CNP egress Bitwarden).
- [x] ~~**SSO Grafana ↔ Zitadel (OIDC)**~~ → CÂBLÉ (2026-07-27). `auth.generic_oauth`
      dans le HelmRelease Grafana, identifiants via ExternalSecret `grafana-oidc`
      (`secret/grafana/oidc`). Endpoints **vérifiés contre la doc Zitadel** :
      `/oauth/v2/authorize`, `/oauth/v2/token`, `/oidc/v1/userinfo`,
      `/oidc/v1/end_session`.
      Deux garde-fous délibérés : le **formulaire local reste actif** (l'admin
      local est le filet si le SSO casse), et les variables d'environnement OIDC
      sont **`optional: true`** — sans ça, un `secret/grafana/oidc` non seedé
      bloquerait le pod et rendrait Grafana totalement inaccessible, l'inverse du
      but recherché.
      ⚠️ Le chemin réseau manquait : la CNP de Grafana n'autorisait **aucun**
      egress vers Zitadel, alors que l'échange du code et `/oidc/v1/userinfo` sont
      des appels SERVEUR-à-serveur. Ajouté des deux côtés (egress Grafana,
      ingress Zitadel), ciblé par namespace + app + port réel.
      **À confirmer au premier déploiement** : la structure du claim de rôles
      (`urn:zitadel:iam:org:project:roles`) — le nom est confirmé, sa forme dépend
      de la configuration de l'application côté Zitadel. `role_attribute_strict:
      false` fait retomber sur `Viewer` plutôt que de refuser l'accès.
      Reste ouvert (mêmes briques) : login OIDC d'OpenBao via Zitadel, et UI
      Longhorn derrière authn.
- [~] **Wave 2 OpenBao TLS interne** (`tls_disable=1`). **Prérequis livré,
      bascule VOLONTAIREMENT non faite** (2026-07-27) — et c'est un choix, pas un
      oubli.

      **Livré** : la dépendance superflue `cert-manager → foundation-vault` est
      retirée. Elle était fausse (la brique cert-manager n'installe que
      l'opérateur et un RBAC dans son propre namespace ; ce sont les ISSUERS, une
      brique à part, qui dépendent d'OpenBao) et elle bloquait tout : cert-manager
      arrivant APRÈS OpenBao, aucun certificat cert-manager ne pouvait servir son
      listener. Gain immédiat au passage : OpenBao n'est plus sur le chemin
      critique d'istio, observability et cluster-api-operator.

      **Pourquoi je n'ai pas basculé** : contrairement au SSO ou aux tokens, ce
      n'est pas un raccordement mais une modification du **chemin critique de
      bootstrap**, avec 8 consommateurs à changer EN MÊME TEMPS —
      `configmap.yaml` (listener + `retry_join` + `leader_api_addr`),
      `statefulset.yaml`, `unsealer.yaml`, `openbao-init.yaml`,
      `bootstrap-roles-job.yaml`, le `ClusterSecretStore` d'ESO, le
      `ClusterIssuer` openbao, et le CronJob de backup. Si un seul est faux, le
      cluster ne monte pas du tout : ni secrets, ni PKI, ni backups. Le livrer
      sans l'avoir vu tourner reviendrait à jouer le prochain déploiement à pile
      ou face.

      **Plan d'exécution, à jouer sur `task local-test` d'abord** (cluster Docker,
      pas de cloud, cycle court) :
      1. Certificat serveur via cert-manager, à partir d'un **Issuer selfSigned →
         CA dédiée**, PAS de la PKI d'OpenBao (sinon OpenBao devrait être debout
         pour obtenir le certificat qui le rend joignable) ; SANs :
         `openbao.foundation-vault.svc.cluster.local`, `openbao`,
         `*.openbao.foundation-vault.svc.cluster.local` (noms par pod du
         headless), `127.0.0.1`, `localhost`.
      2. `tls_disable = 0` + `tls_cert_file`/`tls_key_file` ; `retry_join` en
         `https://` avec `leader_ca_cert_file`.
      3. Les 8 consommateurs : `https://` + CA de confiance (`BAO_CACERT` pour
         les scripts, `caProvider` pour le `ClusterSecretStore`, `caBundle` pour
         le `ClusterIssuer`).
      4. L'HTTPRoute vers l'UI : la gateway parle alors à un backend TLS →
         `BackendTLSPolicy`, sinon l'UI casse en silence.
      5. Vérifier l'ordre de bootstrap complet à froid, pas seulement un cluster
         déjà monté : c'est là que se cachent les cycles.

      ⚠️ Ne pas tenter de substituer ces valeurs par Flux : la brique vault
      contient des variables shell (`$POD_FQDN`) que la substitution viderait —
      même piège que backup, storage et observability.

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
- [x] ~~**Outscale : import de snapshot très lent**~~ → traité : le module pose
      `timeouts { create = "120m" }` sur `outscale_snapshot.talos` (le défaut du
      provider, 40 min, était dépassé par un import mesuré > 60 min en
      `in-queue 0%`), et la marche à suivre en cas de dépassement est écrite sur
      place : attendre `completed` puis `tofu import`, surtout **ne pas**
      relancer l'apply (il déclencherait un second import d'une heure).
- [x] ~~**Purge du staging Outscale**~~ → FAIT et **vérifié en réel**
      (2026-07-27). Le `.raw` de staging (10,9 Gio, un par version) était
      conservé indéfiniment. `terraform_data.purge_staging` le supprime
      désormais après enregistrement de l'OMI.

      ⚠️ **Ce n'était pas qu'un `aws s3 rm` à ajouter** : `data.external.oos_object`
      (presign + `head-object`) est évaluée à CHAQUE plan/refresh alors que ses
      valeurs ne servent qu'à la création du snapshot. Purger sans la rendre
      tolérante à l'absence de l'objet aurait **cassé tout `tofu plan`** du root
      talos-image. La data source dégrade maintenant proprement (url vide,
      taille 0) et `snapshot_size` rejoint `file_location` dans
      `ignore_changes` — les deux viennent de cet objet transitoire.

      Vérifié de bout en bout sur le compte réel : `plan` avant purge =
      *1 to add, 0 to change, 0 to destroy* ; après purge et objet absent =
      **« No changes »**. Les artefacts durables (snapshot `snap-3d4773e8`, OMI
      `ami-16d2bedd`) sont intacts, et le `.raw` est reconstructible à
      l'identique depuis l'Image Factory (schematic ID déterministe).
- [x] ~~**DETTE — state talos-image Outscale désynchronisé**~~ → entrée PÉRIMÉE,
      vérifiée le 2026-07-27 : `tofu state list` montre le snapshot ET l'OMI, aux
      IDs exacts présents sur le compte (`snap-3d4773e8`, `ami-16d2bedd`). La
      réconciliation a eu lieu au rebuild du 2026-07-26 ; les IDs cités dans
      l'ancienne entrée (`ami-6711ec55`, `snap-6bc67b02`) n'existent plus.

      ⚠️ **Piège de diagnostic** : le tfstate est **chiffré côté client**. Le
      télécharger et le lire en JSON montre `resources: []` — ce qui ressemble à
      un état vide et m'a d'abord fait conclure à tort. Toujours passer par
      `tofu state list` avec `TF_VAR_encryption_passphrase`.
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
