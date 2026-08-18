> 🇬🇧 [English version](first-cluster.md) — la version anglaise fait foi.

# Ton premier cluster

D'une machine nue et d'un compte cloud vide jusqu'à un cluster Talos que tu peux
joindre, mettre à jour et détruire. Scaleway sert d'exemple ; OVH et Outscale n'en
diffèrent guère que par leurs identifiants et leur fichier tfvars — à deux
exceptions près : l'étape 4, bien plus lente sur Outscale, et l'étape 7, un défaut
ouvert connu sur OVH.

**Lis la note d'honnêteté en fin de page avant de dépenser quoi que ce soit.**
Une partie de ce chemin n'a jamais été parcourue de bout en bout, et ce document
dit laquelle.

## Ce que tu obtiens, et ce que tu n'obtiens pas

Un cluster Talos : 3 control planes, 2 workers, Cilium comme CNI, un load
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
- Une paire de clés SSH, ou `ssh-keygen -t ed25519`.
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

Et celle qui compte le plus :

```bash
TF_VAR_encryption_passphrase="$(openssl rand -base64 48)"
```

Minimum 32 caractères — et **le texte d'exemple livré dans `.env.example` est
assez long pour passer cette validation** : rien ne t'empêchera de déployer avec.
Remplace-le. Perdre cette passphrase, c'est perdre l'état et les deux artefacts
d'accès.

N'exporte pas `AWS_*` toi-même : le flux les dérive par provider à partir des
variables préfixées ci-dessus.

Rien ne vérifie ce fichier. La première commande qui signale un identifiant
manquant s'exécute après que `task up` a déjà créé un bucket.

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
| `environment` | `dev` ou `prod`, rien d'autre. `prod` exige en plus que le réplica soit sur un autre provider |
| `admin_ip` | `curl -s ifconfig.me` en `/32`. C'est à la fois la liste d'autorisation SSH et l'ACL du LB apiserver |
| `s3_primary_endpoint` / `_region` | le S3 sur le même provider que le cluster |
| `s3_replica_endpoint` / `_region` | le S3 de la copie de sauvegarde. En production, **un autre provider** : un état qu'on ne peut lire que depuis le cloud qui vient de tomber n'est pas une sauvegarde |
| `bastion_ssh_keys` | la moitié **publique** de la clé passée en `KEY=`. `task up` refuse de démarrer si elles ne correspondent pas, avant toute dépense |
| `control_planes` | 3. Rien ne le valide ; `2` construit silencieusement un etcd à deux membres |

`git_repo_url`, `git_ref`, `flux_namespace` et `apps_profile` sont inertes tant
que Flux est désactivé. Laisse-les.

## 4. Le déploiement

```bash
cd ../../../..
task up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

Demande un terminal : l'apply sollicite une approbation deux fois, et il applique
le plan qu'il vient de montrer — n'utilise pas `-auto-approve`, qui en applique
un *autre*, recalculé à cet instant. (Pour un run non supervisé, enregistre-le
d'abord : `task plan … OUT=tfplan`, relis-le, puis `task apply-plan PLAN=tfplan`.)

Dans l'ordre, il construit l'image Talos et la téléverse — **mesuré à 52 s sur
Scaleway le 2026-08-17**, pour deux buckets, un snapshot et une image par zone —
crée quatre buckets de plus, applique l'infrastructure, ouvre un tunnel SSH par
nœud, puis applique les configurations machine et amorce Talos.

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
applicatif, et un réplica de l'état existe dans le magasin de sauvegarde.

Chaque vérification peut échouer. Une vérification qui avertit et finit verte est
le défaut que ce fichier existe pour éviter.

## 7. Mettre à jour

`docs/upgrade.md` est la procédure — Kubernetes d'abord, puis Talos, un nœud à la
fois, en place. Lance la sonde avant de commencer : l'affirmation de ce projet
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
task restore-artifacts PROVIDER=scaleway FROM=replica    # quand c'est ce fournisseur, le problème
```

`FROM=replica` lit le second magasin avec ses propres identifiants — en
production un autre fournisseur, et c'est tout l'intérêt : une copie qu'on ne
peut lire que depuis le cloud qui vient de tomber n'est pas une sauvegarde.

Il n'écrase pas un fichier déjà présent sans `FORCE=1` ; sinon la copie
récupérée atterrit à côté, en `kubeconfig.restored`.

Rien ne les récupère sans `TF_VAR_encryption_passphrase`. Il n'y a pas de
seconde clé, ni de réinitialisation.

## Ce qui n'est pas prouvé

Honnête au moment de la 0.5.0, et c'est la raison d'être de ce document :

- **Ce chemin n'a jamais été parcouru de bout en bout depuis une machine
  propre.** Il a été assemblé en lisant le code, pas en le suivant.
- `task verify` n'a jamais tourné contre un cluster cloud. Ses contrôles passent
  sur un cluster Docker local vivant (6/6, 2026-08-17), et les branches propres
  au cloud — le nombre de control planes comparé à l'état, le load balancer
  applicatif, le réplica — n'ont jamais été exécutées nulle part.
- Rien n'a jamais ouvert un objet d'*état* stocké pour confirmer qu'il est
  chiffré. Le chiffrement est déclaré et implémenté ; il n'est pas vérifié sur S3.
- L'aller-retour de restauration est prouvé hors ligne : la vraie fonction de
  chiffrement contre la vraie fonction de déchiffrement, octet pour octet,
  mauvaise passphrase refusée (`scripts/dev/test-restore.sh`). Ce qui n'est
  **pas** prouvé, c'est le transport — que l'objet soit réellement dans le bucket
  et en revienne. C'est l'une des raisons d'être du premier run payant.
- L'upgrade Talos est prouvé sur Scaleway. Sur OVH, des nœuds sont revenus sur la
  version précédente, et c'est ouvert.
- Tous les noms de buckets dérivent de `cluster_name`, sauf ceux de l'image
  Talos, qui sont codés en dur. Dans un autre compte ils peuvent entrer en
  collision.

Tu trouves une erreur dans ce document ? C'est le rapport de bug le plus utile
que ce projet puisse recevoir.
