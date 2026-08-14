# Mettre à niveau un cluster vivant — Kubernetes et Talos

🇬🇧 [English version](upgrade.md)

> Construire un cluster et en garder un sont deux affirmations différentes. Voici
> la seconde. Prouvée à la main sur Scaleway, OVH et Outscale le 2026-08-13, en
> topologie HA, chaque nœud mis à niveau **sur place** plutôt que remplacé.
>
> La version non assistée de cette même procédure est
> [`scripts/dev/staging-upgrade.sh`](../scripts/dev/staging-upgrade.sh), jouée
> chaque semaine par `.github/workflows/staging.yml`. Si les deux divergent, c'est
> le script qui fait foi — c'est lui qui tourne.

## Les deux faits dont découle tout le reste

**L'image de boot d'un nœud n'est que le médium depuis lequel il a été installé.**
Après un `talosctl upgrade`, l'instance rapporte toujours l'ancien id d'image,
par construction. Les ressources de nœud portent donc `ignore_changes` dessus —
voir
[`provider-contract.md` § Node image drift](../infrastructure/opentofu/modules/providers/provider-contract.md).
Sans cela, bumper `talos_version` ferait remplacer les trois control planes en
même temps par un apply de routine, et etcd perdrait son quorum.

**Talos ne supporte qu'une fenêtre de versions Kubernetes.**
`cluster/versions-guard.tf` refuse une paire non supportée dès le plan, et refuse
aussi une mineure Talos que personne n'a saisie dans sa table plutôt que de la
laisser passer en silence. La paire de départ, celle d'arrivée **et** l'état
intermédiaire doivent tenir dans la fenêtre, puisque les deux bougent l'une après
l'autre.

## Mesurer l'interruption

À lancer avant tout le reste, contre l'endpoint du kubeconfig — jamais contre un
tunnel vers un nœud, puisque c'est ce nœud-là qu'on s'apprête à retirer.

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

Une exécution propre perd quelques secondes le temps qu'un apiserver redémarre.
Celle du 2026-08-13 en a perdu trois.

## Kubernetes d'abord

Elle ne redémarre rien, ce qui isole le roulement du control plane de celui des
nœuds.

```bash
# modifier kubernetes_version dans envs/<role>-<provider>.tfvars, puis
task infra ROLE=management PROVIDER=<p>
```

Talos réconcilie les static pods et les kubelets ; attendre que chaque nœud
rapporte la nouvelle version avant de continuer. À noter : ce chemin contourne
`talosctl upgrade-k8s`, qui séquence ces composants derrière des health checks —
voir `backlog.md`.

## Puis Talos, sur place

Bumper `talos_version`, construire l'image de la nouvelle version (les ressources
de nœud ignorent l'image, mais la *data source*, elle, doit résoudre), appliquer,
puis dérouler.

```bash
task talos-image PROVIDER=<p> VERSION=<new> ENSURE=1
# modifier talos_version dans le tfvars, puis
task infra ROLE=management PROVIDER=<p>
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<clé> -- --cp-only --upgrade
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<clé> -- --workers-only --upgrade
```

`--upgrade` appelle `talosctl upgrade`, qui conserve le disque, l'identité et
l'appartenance etcd du nœud, le drain lui-même, et refuse une mise à niveau de
control plane qui coûterait son quorum à etcd. Un nœud à la fois, avec une porte
de santé entre chacun, et rejouable : un nœud déjà sur la version cible est
sauté. Les control planes d'abord — un worker a besoin d'un control plane sain
pour se drainer.

### Le roll s'arrête sur un nœud portant un primaire de base. C'est correct.

`rolling-replace` refuse de redémarrer un nœud qu'il n'a pas pu drainer, et un
primaire CNPG **ne peut pas être évincé** : sa PodDisruptionBudget l'interdit
jusqu'à un switchover, et sur `local-path-retain` l'instance ne pourrait de toute
façon pas aller sur un autre nœud. Le roll place chaque Cluster CNPG en
`nodeMaintenanceWindow` pour sa durée, ce qui est nécessaire et pas suffisant —
mesuré sur Scaleway le 2026-08-14, où un worker portait *deux* primaires.

C'est donc une étape manuelle aujourd'hui. Quand le roll s'arrête en nommant un
pod `*-db-N` :

```bash
# 1. quelle instance est primaire, et où
kubectl get cluster -A -o custom-columns=NS:.metadata.namespace,\
NAME:.metadata.name,PRIMARY:.status.currentPrimary
kubectl get pod <primaire> -n <ns> -o jsonpath='{.spec.nodeName}{"\n"}'

# 2. la basculer vers un réplica sain d'un AUTRE nœud
kubectl cnpg promote <cluster> <replica> -n <ns>     # plugin kubectl-cnpg

# 3. relancer la MÊME commande — les nœuds déjà à la version cible sont sautés
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<clé> -- --workers-only --upgrade
```

Ne pas passer en force. La version que ceci remplace avertissait puis redémarrait
le nœud quand même, ce qui a laissé `zitadel-db` bloqué en switchover et
`grafana-db` sans instance active. Savoir si une anti-affinité de pods
permettrait à CNPG de quitter seul un nœud cordoné — et de supprimer cette
étape — est une question ouverte dans `backlog.md`.

⚠️ **Le premier apply après un bump de `talos_version` échoue sur OVH et
Outscale** avec « Provider produced inconsistent final plan », une fois par
machine config. Rien n'est laissé à moitié appliqué ; relancer. C'est l'issue
amont `siderolabs/terraform-provider-talos` #352, corrigée seulement dans la
ligne 0.12.0 en pré-version — détails et décision encore ouverte dans
`backlog.md`.

## Ce qu'il faut vérifier, au-delà de « c'est revenu »

Après chaque nœud, puis à la fin :

- **son nom n'a pas changé** — une entrée `talos-xxxxx` signifie que le hostname
  n'a pas tenu, et le prochain reboot orphelinera un autre objet node
- le nombre de nœuds n'a pas augmenté, et etcd rapporte toujours tous ses membres
- le compteur de FAIL de la sonde n'a presque pas bougé
- **`tofu plan` est vide.** S'il veut remplacer des nœuds, l'image de boot et la
  version qui tourne ont divergé — ce plan-là coucherait le cluster. S'arrêter et
  lire § Node image drift avant de lancer quoi que ce soit d'autre.

```bash
task plan ROLE=management PROVIDER=<p> STRICT=1   # sortie 2 = non convergé
```

## Remplacer un nœud plutôt que le mettre à niveau

`--upgrade` ne peut pas porter un changement d'`instance_type`, de disque ou de
zone, ni un nouveau schematic d'image : ceux-là exigent une nouvelle VM. Même
script, sans `--upgrade` : il draine, applique un `-replace` ciblé et attend, un
nœud à la fois. Ce chemin-là, lui, exige que la nouvelle image cloud existe.
