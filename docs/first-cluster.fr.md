> 🇬🇧 [English version](first-cluster.md) — la version anglaise fait foi.

# Ton premier cluster

D'une machine nue et d'un compte cloud vide jusqu'à un cluster Talos que tu peux
joindre, mettre à jour et détruire. Scaleway sert d'exemple ; OVH et Outscale n'en
diffèrent guère que par leurs identifiants et leur fichier tfvars — sauf à
l'étape 4, bien plus lente sur Outscale, et plus lente encore pour le load
balancer OVH.

**Lis la note d'honnêteté en fin de page avant de dépenser quoi que ce soit.**
Elle dit ce qui a été mesuré, sur quel cloud et quand — et ce qui ne l'a pas été.

## Ce que tu obtiens, et ce que tu n'obtiens pas

Un unique cluster Talos Linux : 3 control planes, 2 workers, Cilium comme CNI, un load
balancer d'apiserver filtré sur ton IP, un bastion, et un état OpenTofu chiffré
chez toi avant d'atteindre S3.

Aucune application, pas de GitOps, pas d'ingress. Flux existe dans le code et est
**désactivé** (`deploy_flux = false`) ; il redeviendra un choix dans une version
ultérieure. Cilium n'en a pas besoin : Talos livre Cilium lui-même, en manifeste
inline, avant que quoi que ce soit d'autre ne démarre.

## Avant de commencer

- Un compte Scaleway, et le quota pour **5 instances** du type indiqué dans ton
  tfvars. Un compte neuf peut être plafonné à 1 — Console → Quotas. Il n'existe
  pas de script de préflight pour Scaleway (`preflight-quotas.py` ne couvre
  qu'OVH et Outscale) : cette vérification est à ta charge.
- Une paire de clés SSH que tu possèdes déjà, ou `ssh-keygen -t ed25519`.
- De quoi conserver une passphrase que tu ne peux pas te permettre de perdre :
  elle chiffre l'état, le kubeconfig et le talosconfig, et rien ne les déchiffre
  sans elle.

## 1. La machine

```bash
git clone https://github.com/dis-bzh/OpenAether-infra && cd OpenAether-infra
./scripts/setup.sh
```

Installe OpenTofu, talosctl, kubectl, Task, l'AWS CLI, gpg et le reste. Demande
root ou sudo. Se termine sur `🚀 Environment ready!`.

Ne commence **pas** par `task setup` : `task` fait partie de ce que ce script
installe.

## 2. Les identifiants

```bash
cp .env.example .env.sh
$EDITOR .env.sh
source .env.sh
```

À remplir, pour Scaleway : `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`,
`SCW_DEFAULT_PROJECT_ID`, `SCW_DEFAULT_ORGANIZATION_ID`, la région et la zone,
puis `SCW_AWS_ACCESS_KEY_ID` / `SCW_AWS_SECRET_ACCESS_KEY` pour S3.

Il existe une SECONDE paire, facile à manquer :
`SCW_BACKUP_AWS_ACCESS_KEY_ID` / `SCW_BACKUP_AWS_SECRET_ACCESS_KEY` (ou la
générique `BACKUP_AWS_*`). `.env.example` la fait pointer sur les clés du
primaire, ce qui n'est juste que tant que les deux magasins vivent chez le même
fournisseur. Dès que tu suis le conseil de production de l'étape 3 et places le
réplica ailleurs, ce doivent être les clés de CE fournisseur-là — elles sont
nommées d'après le provider du CLUSTER, pas du backup, si bien qu'un cluster
Scaleway sauvegardant chez OVH met la clé OVH dans `SCW_BACKUP_AWS_*`.
Contre-intuitif, et déterminant : `task up` refuse de continuer si le réplica
pointe ailleurs et que les buckets `-backup` n'y sont pas créables.

Et celle qui compte le plus :

```bash
TF_VAR_encryption_passphrase="$(openssl rand -base64 48)"
```

Minimum 32 caractères. `task up` refuse net si elle n'est pas définie, et refuse
encore si elle contient toujours `change-me` : le texte d'exemple est publié dans
ce dépôt, et ce contrôle est la seule chose entre toi et un déploiement sous un
secret public. Perdre cette passphrase, c'est perdre l'état et les deux artefacts
d'accès.

N'exporte pas `AWS_*` toi-même : le flux les dérive par provider à partir des
variables préfixées ci-dessus.

`task up` vérifie ce fichier avant de dépenser quoi que ce soit : la clé SSH
existe et est bien la moitié privée de `bastion_ssh_keys`, le fichier tfvars
existe, les DEUX paires d'identifiants S3 se résolvent, et la passphrase est
définie et n'est pas le texte d'exemple. Tout cela tourne avant le premier
bucket.

## 3. Le fichier du cluster

```bash
cd infrastructure/opentofu/cluster/envs
cp management-scaleway.tfvars.example management-scaleway.tfvars
$EDITOR management-scaleway.tfvars
```

| champ | ce qu'il faut y mettre |
|---|---|
| `cluster_name` | le tien. **Il a une valeur par défaut, donc aucun contrôle ne te dira de le changer** — et son premier segment nomme les quatre buckets du cluster |
| `bucket_suffix` | **à renseigner sauf si tu es l'auteur d'origine.** Les noms de bucket S3 sont uniques à l'échelle d'un fournisseur entier, pas d'un compte — Scaleway les documente uniques « in our whole platform », OVH « within OVHcloud ». Sans lui tu entreras en collision avec des noms déjà pris. `task bucket-suffix` en imprime un ; choisis-le une fois, le changer ensuite orpheline tous tes buckets |
| `environment` | `dev` ou `prod`, rien d'autre. Il n'*exige* rien : aucune validation ne regarde le réplica avant que tu dépenses. Un `prod` dont le réplica pointe sur l'endpoint primaire se déploie sans broncher, et `task verify` le déclare rouge après coup |
| `admin_ip` | `curl -s ifconfig.me` en `/32`. C'est à la fois la liste d'autorisation SSH et l'ACL du LB apiserver |
| `s3_primary_endpoint` / `_region` | le S3 sur le même provider que le cluster |
| `s3_replica_endpoint` / `_region` | le S3 de la copie de sauvegarde. En production, **un autre provider** : un état qu'on ne peut lire que depuis le cloud qui vient de tomber n'est pas une sauvegarde. Exporte dans la même édition les clés `<PROV>_BACKUP_AWS_*` de CE magasin : `task up` refuse de continuer si le réplica pointe ailleurs et que les buckets `-backup` n'y sont pas créables |
| `bastion_ssh_keys` | la moitié **publique** de la clé passée en `KEY=`. `task up` refuse de démarrer si elles ne correspondent pas, avant toute dépense |
| `control_planes` | 3 — **à l'intérieur de `node_distribution.<provider>`**, pas un champ de premier niveau, et `bastion_ssh_keys` est une map indexée par provider de la même façon. Rien ne valide le nombre ; `2` construit silencieusement un etcd à deux membres |

`git_repo_url`, `git_ref`, `flux_namespace` et `apps_profile` sont inertes tant
que Flux est désactivé. Laisse-les.

Avant de dépenser quoi que ce soit : `task preflight`. Lint, rendu, validation,
tests unitaires et tests de scripts — tout ce qui se prouve sans compte cloud, en
une commande et environ quatre minutes. C'est gratuit, et c'est le bug le moins
cher que tu trouveras jamais.

## 4. Le déploiement

```bash
cd ../../../..
task up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

Demande un terminal : l'apply sollicite une approbation deux fois, et il applique
le plan qu'il vient de montrer — n'utilise pas `-auto-approve`, qui en applique
un *autre*, recalculé à cet instant. (Pour un run non supervisé, enregistre-le
d'abord : `task plan ROLE=management PROVIDER=scaleway OUT=tfplan`, relis-le,
puis `task apply-plan PROVIDER=scaleway PLAN=tfplan`. `PROVIDER` est exigé sur
les deux — il retombait avant sur Scaleway, ce qui est le mauvais cloud à
deviner.)

Dans l'ordre, il construit l'image Talos et la téléverse — **mesuré à 52 s sur
Scaleway le 2026-08-17**, pour deux buckets, un snapshot et une image par zone —
crée quatre buckets de plus, applique l'infrastructure, ouvre un tunnel SSH par
nœud, puis applique les configurations machine et amorce Talos.

**Le load balancer de l'apiserver est ce qu'il y a de plus lent dans cette
étape, et le seul objet qui peut te laisser en rade.** Rapide chez Scaleway. Chez
OVH et Outscale c'est un service managé qui se construit de façon asynchrone :
mesuré à **plus de 30 minutes toujours en « PENDING_CREATE » chez OVH, le
2026-08-18**, et c'est un LB Outscale expirant à 10 minutes qui l'a révélé le
2026-08-16. L'apply n'affiche rien d'autre que `Still creating...` ; l'état réel
est dans l'API du provider.

En cas de timeout, **ne relance pas bêtement.** OpenTofu marque la ressource
`tainted`, donc l'apply suivant **détruit** le load balancer que le provider était
en train de finir et recommence l'attente. `task infra` imprime désormais les
adresses tainted et la commande `tofu untaint` quand il échoue : demande d'abord
au provider, et garde la ressource s'il la dit saine.

Et s'il est réellement coincé, ce n'est pas réparable de ton côté : un LB managé
réserve un port **dans ton propre sous-réseau** avant que son backend existe, si
bien qu'un LB bloqué ne peut plus être supprimé et retient le sous-réseau, le
réseau, et tout ton teardown derrière lui. `task down` le reconnaît et te le dit,
au lieu de te conseiller de réessayer. C'est un ticket support.

**Sur Outscale, cette première étape se compte en minutes voire en heure, pas en
secondes**, et cela vient du provider, pas de ce projet. Outscale enregistre une
image à partir d'un snapshot IMPORTÉ depuis un objet de 11 Gio, et cet import
patiente dans une file côté provider : **8 min de bout en bout le 2026-08-18, et
plus de 60 min bloqué à `in-queue 0%` le 2026-07-25**. Deux mesures, un ordre de
grandeur d'écart : prévois la lente. Rien n'est cassé pendant l'attente ;
`ReadSnapshots` donne l'état et la progression réels si tu veux la voir avancer.
La même attente revient à chaque changement de version Talos, upgrade compris.

Six buckets existent ensuite : l'état et les artefacts, chacun avec son jumeau
`-backup`, plus l'image et sa zone de préparation.

Relancer reprend où ça s'est arrêté — **sauf si ta modification ajoute un nœud**,
qui est un défaut ouvert connu (`docs/backlog.md`), pas une erreur de ta part.

## 5. Joindre le cluster

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu/cluster/kubeconfig
kubectl get nodes
```

Le fichier est déjà là, écrit par le bootstrap. Sinon, ou depuis un shell neuf :
`task kubeconfig PROVIDER=scaleway`.

L'apiserver est le load balancer public, filtré sur ton `admin_ip` : `kubectl`
fonctionne directement, sans tunnel.

Pour Talos, chaque commande exige un nœud explicite — le talosconfig porte des
endpoints mais aucun nœud par défaut :

```bash
cd infrastructure/opentofu/cluster
talosctl --talosconfig talosconfig -n "$(tofu output -json control_plane_private_ips | jq -r '.[0]')" etcd members
```

Ces endpoints sont des **tunnels locaux**. `task close-tunnels` rend le
talosconfig inutilisable jusqu'à leur réouverture.

## 6. Demander au cluster si ça a marché

```bash
task verify PROVIDER=scaleway
```

Interroge le cluster, pas l'outil : l'apiserver répond, chaque nœud est Ready, le
nombre de control planes correspond à ce que tu as demandé, Cilium tourne sur
chacun, CoreDNS sert, il n'y a pas de `flux-system`, pas de load balancer
applicatif, un réplica de l'état existe dans le magasin de sauvegarde — et les
4 premiers Kio de cet objet sont ouverts : ce doit être une enveloppe OpenTofu
`encrypted_data`, pas un état lisible. Hors `dev`, le réplica doit en outre être
un endpoint différent du primaire.

Aucune vérification ne finit verte sur un avertissement. Deux situations
avertissent délibérément, et aucune ne passe : un control plane qui n'est pas HA,
et un réplica de `dev` partageant l'endpoint du primaire. Un contrôle que le
vérificateur n'a pas pu effectuer du tout est compté à part en `?` et reste tout
aussi fatal — rien n'est certifié sur une question que personne n'a pu poser.

## 7. Mettre à jour

```bash
task upgrade ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

`docs/upgrade.md` est la procédure derrière — Kubernetes d'abord, puis Talos, un
nœud à la fois, en place. Elle refuse si le cluster tourne déjà sur les deux
cibles : un upgrade ne se prouve que depuis un cran en dessous, et elle lit le
CLUSTER, pas ton tfvars. Lance la sonde avant de commencer : l'affirmation de ce projet
n'est pas « sans interruption », c'est **la plus longue série d'échecs
consécutifs de `/readyz`, à une seconde d'intervalle, reste sous 15 secondes**.
Mesure-la.

Mesuré sur Scaleway le 2026-08-17, 3 control planes : **7 échantillons en échec
sur 1817, plus longue coupure 3 s**, sur les deux upgrades. Les deux nombres sont
des affirmations différentes — des ratés dispersés pendant un roulement de
control planes, c'est un cluster HA qui fonctionne ; consécutifs, c'est l'API à
terre.

## 8. Détruire

```bash
task destroy ROLE=management PROVIDER=scaleway
task down PROVIDER=scaleway -- --force-no-edges --yes
python3 scripts/ops/purge-orphans/scaleway.py
```

`--force-no-edges` est obligatoire et le `--` nu ne l'est pas moins. `fleet-down`
refuse de détruire tant qu'il n'a pas écarté l'existence de clusters enfants
CAPI ; un cluster d'infrastructure pure n'a pas les CRD CAPI, donc cette requête
ne peut jamais aboutir, et le drapeau est la façon de dire qu'il n'y en a aucun.

Les buckets et l'image Talos survivent volontairement — supprimer le bucket
d'état supprime aussi toute possibilité de restauration. `fleet-down` les liste
par leur nom.

Plus rien ne doit être facturé ensuite. Le script de purge interroge le provider
plutôt que le fichier d'état ; c'est la seule réponse qui compte.

## 9. Si tu perds l'accès

Le kubeconfig et le talosconfig sont chiffrés sur ta machine et copiés dans les
deux magasins à chaque changement du cluster. Pour les récupérer :

```bash
task restore-artifacts PROVIDER=scaleway                 # depuis le magasin primaire
task restore-artifacts PROVIDER=scaleway FROM=replica    # quand c'est ce fournisseur qui est le problème
```

`FROM=replica` lit le second magasin avec ses propres identifiants — en
production un autre fournisseur, et c'est tout l'intérêt : une copie qu'on ne
peut lire que depuis le cloud qui vient de tomber n'est pas une sauvegarde.

Il n'écrase pas un fichier déjà présent sans `FORCE=1` ; sinon la copie
récupérée atterrit à côté, en `kubeconfig.restored`.

Rien ne les récupère sans `TF_VAR_encryption_passphrase`. Il n'y a pas de
seconde clé, ni de réinitialisation.

## Ce qui n'est pas prouvé

Honnête au moment de la 0.5.0, et c'est la raison d'être de ce document.

Ce qui **est** mesuré, avec les dates (`docs/backlog.md`, « Where we stand ») :

- `task verify` donne **9/9 sur Scaleway, 9/9 sur Outscale, 10/10 sur OVH** — la
  dixième assertion étant le réplica hébergé chez un autre fournisseur. Le
  cluster Docker local exécute 6 de ces contrôles.
- **L'état stocké a été ouvert.** Une enveloppe `encrypted_data` sous SSE-AES256,
  récupérée depuis le bucket `-backup` à l'endpoint d'un AUTRE fournisseur, avec
  les identifiants de ce fournisseur, le 2026-08-19. Pas déclaré : téléchargé et
  inspecté.
- Les deux artefacts d'accès ont été restaurés depuis les deux magasins, octet
  pour octet identiques aux fichiers vivants, le 2026-08-17.
- **L'upgrade Talos est passé sur les trois clouds**, 6/6 nœuds chacun. Coupure
  d'API la plus longue mesurée : 3 s sur Scaleway, 1 s sur Outscale, 1 s sur OVH.

Ce qui reste ouvert :

- **Le chemin Scaleway a été parcouru de bout en bout le 2026-08-17**, mais
  depuis une machine qui avait déjà la chaîne d'outils — l'étape 1 sur un hôte nu
  n'a jamais été suivie. OVH et Outscale ont été pilotés par leur opérateur, pas
  en suivant cette page.
- **Le failover complet.** Le fournisseur A traité comme perdu, l'état et les
  artefacts récupérés depuis B seul, le cluster reconstruit chez B.
  `envs/failover-*.tfvars.example` existe exactement pour ça et n'a jamais servi.
  Le transport en dessous est prouvé ; le failover, non.
- **Personne n'a déployé avec un `bucket_suffix` non vide.** Six dérivations
  concordent en tests unitaires ; le jour où quelqu'un en posera un sera le
  premier où le backend, la construction d'image et le vérificateur devront
  s'accorder pour de vrai.
- **Sur OVH, un control plane est reparti sur la version précédente après un
  upgrade.** Sa cause — une extension système que nous livrions et qui ne
  démarrait jamais, si bien que Talos n'atteignait jamais `Running` et ne
  désarmait jamais le repli d'upgrade — a été retirée du schematic le 2026-08-19.
  C'est une non-récurrence, pas encore une preuve.
- Tous les noms de buckets dérivent de `cluster_name` (son premier segment, plus
  `bucket_suffix`), sauf ceux de l'image Talos, codés en dur. Dans un autre
  compte ils peuvent entrer en collision.

Tu trouves une erreur dans ce document ? C'est le rapport de bug le plus utile
que ce projet puisse recevoir.
