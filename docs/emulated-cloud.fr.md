# Cloud émulé (Feint) — tester Scaleway et Outscale sans compte

🇬🇧 [English version](emulated-cloud.md)

[Feint](https://github.com/stephrobert/feint) est un émulateur local des APIs
Scaleway, Outscale et Exoscale : un binaire Go statique sur `127.0.0.1:4599`,
aucun compte, aucune facture. Ce dépôt y pointe les **vrais** binaires providers
Scaleway et Outscale : le provider parle donc en HTTP réel à une vraie API, sans
le moindre credential à portée.

C'est un cran au-dessus de l'existant. `task validate` vérifie la syntaxe ;
`task test` mocke le provider et ne sort jamais du processus ; `task local-up`
exerce `modules/talos` sur Docker mais aucun module provider cloud. Outscale, en
particulier, n'avait **aucune couverture en mode apply**.

La couverture et les limites de Feint sont documentées en amont — les lire
là-bas plutôt qu'ici, elles bougent :
[`docs/limits.md`](https://github.com/stephrobert/feint/blob/main/docs/limits.md).

## Utilisation

```bash
task feint-up                          # démarre l'émulateur (installe le binaire épinglé si absent)
task feint-plan   PROVIDER=scaleway    # plan du VRAI root cluster, sans credentials
task feint-apply  PROVIDER=outscale    # cycle apply/destroy sur la fixture réduite
task feint-record PROVIDER=scaleway    # classe ce que notre module appelle et qu'aucun pack ne sert
task feint-test                        # les deux providers, plan + apply
task feint-down
```

## Trois voies, parce qu'une seule ne peut pas faire les trois

**`feint-plan` — le vrai root `cluster`, plan seulement.** Vrais modules, vrai
provider, `envs/feint-<provider>.tfvars.example`. Impossible d'aller plus loin
que le `plan`, et ce qui l'en empêche tient désormais en une liste courte :

- **Scaleway** : le module crée toujours une public gateway et des réservations
  IPAM. La gateway n'est pas servie ; la réservation IPAM est déclinée
  volontairement. Inchangé depuis **Feint** 0.5.0 — aucune version jusqu'à
  l'enregistrement 0.7.3 ci-dessous n'a fait bouger le pack Scaleway.
- **Outscale** : les load balancers, et rien d'autre — et c'est une décision, pas
  un manque. La 0.6.0 a fait passer le pack de 31 à 72 routes : security groups,
  IP publiques, internet service, NAT service, route tables et NICs fonctionnent
  tous ; la 0.7.0 n'y ajoute aucune route mais a fait cesser le segfault de
  `data.outscale_images`, ce qui permet à cette voie de résoudre son image par
  la data source.

Le root déclarant un backend S3 partiel, la voie y dépose un `*_override.tf` de
backend local et le retire en sortant.

**`feint-apply` — `infrastructure/opentofu-feint/`, un vrai cycle CRUD.** Un root
séparé (même principe que `infrastructure/opentofu-local`) qui porte les mêmes
formes sur le sous-ensemble réellement servi : init → validate → plan → apply →
**second plan vide** → destroy, l'existence comme la disparition étant relues
depuis l'API et non depuis le state. Voir son
[README](../infrastructure/opentofu-feint/README.md).

**`feint-record` — mesurer le mur au lieu d'en discuter.** `feint proxy`
s'intercale entre le provider et l'émulateur et écrit un objet JSON caviardé par
échange ; `feint transcript` classe ensuite les opérations qu'aucun pack ne sert,
les plus appelées d'abord. L'apply derrière est *censé* échouer, au premier appel
non servi — tout ce qui précède est justement ce qui est enregistré. Résultat
actuel, reproductible avec les commandes ci-dessus :

| Provider | Appelé, servi par personne | Appels | Manquant, ou décliné ? |
|---|---|---|---|
| Scaleway | `POST /ipam/v1/regions/fr-par/ips` (501) | 2 | Décliné — le `GET` sur le même chemin répond 200 |
| Scaleway | `/lb/v1/zones/fr-par-1/ips` (501) | 2 | Manquant |
| Scaleway | `/vpc-gw/v2/zones/fr-par-1/ips` (501) | 1 | Manquant |
| Outscale | `/api/v1/CreateLoadBalancer` (404) | 2 | Décliné |

Les mêmes trois opérations en 0.6.0, 0.7.0 et 0.7.3 : aucune version n'a bougé
quoi que ce soit qu'appellent nos modules. Ce qui a bougé, c'est la *forme* du
refus — les deux manques Scaleway répondaient un `404` en texte brut jusqu'à la
0.7.3, que le SDK jetait pour son content type, si bien que l'appelant voyait
`404 Not Found` et pas de corps. Ils répondent maintenant `501` dans le dialecte
de Scaleway (notre issue #74). La distinction de la dernière colonne est tout
l'intérêt de rejouer la mesure — une route manquante est un trou que quelqu'un
peut combler, un decline est une réponse.

L'amont est ici l'émulateur, pas le cloud. Un client qui signe l'hôte pour lequel
il a été configuré — le provider Terraform le fait — ne peut pas être enregistré
contre un vrai cloud à travers un simple reverse proxy, puisque le cloud vérifie
la signature contre son propre nom et répond 401. La 0.7.0 traite cette autre
moitié séparément, avec `feint shapes` et un signataire par provider ; cette voie
reste délibérément celle sans credential, et répond *ce que nous appelons et qui
manque* plutôt que ce que le vrai cloud renvoie.

## Le garde-fou

Le dépôt de Feint a lui-même créé un serveur facturé parce qu'une redirection
valait la chaîne vide et que le client est retombé sur le profil stocké de
l'opérateur. Tous les clients cloud officiels font ça. Donc :

- `emulator_api_url` (et le `endpoint` de la fixture) **n'acceptent qu'une URL
  loopback** — une valeur distante est une erreur de validation, pas un
  avertissement ;
- `scripts/dev/feint.sh` refuse un endpoint non loopback et vide toutes les
  variables `SCW_*` / `OSC_*` avant de lancer quoi que ce soit ;
- quand l'émulateur est actif, les blocs provider **épinglent** des credentials
  factices : le provider ne peut pas aller en chercher des vrais.

## Ce que ça prouve, et ce que ça ne prouve pas

**Prouve** : la configuration provider est acceptée et tout le graphe se résout
sans credential ; un vrai cycle create/read/update/delete sur le sous-ensemble
servi ; et, via le second plan vide, que chaque attribut envoyé revient
identique — c'est là qu'un champ inventé ou perdu se voit.

**Ne prouve pas qu'un déploiement réel fonctionne.** L'émulateur n'a pas
d'inventaire : un id d'image ou un type de machine qui n'existe nulle part est
*accepté*, là où le vrai cloud refuse. Pas de load balancer, pas de gateway, pas
de quotas, pas de latence, transitions d'état immédiates, authentification jamais
vérifiée. Le cloud réel reste la seule preuve d'un déploiement ; ceci attrape les
régressions de câblage avant de dépenser.

## Manques connus

Épinglé sur **Feint 0.12.0** (`scripts/dev/feint.sh`). Ce que cette voie ne peut
toujours pas porter, tout consigné dans [les issues ouvertes](https://github.com/dis-bzh/OpenAether-infra/issues) :

| Non exercé | Pourquoi |
|---|---|
| Load balancers Outscale | `CreateLoadBalancer` est **décliné volontairement**, pas manquant : un load balancer est un plan de données que l'émulateur n'a pas, en créer un rendrait un nom DNS ne résolvant nulle part. `ReadLoadBalancers` répond une liste vide. Celui-là ne bougera pas. |
| Réservations IPAM Scaleway | Décliné aussi, avec une raison : les adresses viennent du plan de sous-réseau où le NIC est placé, donc `BookIP` distribuerait une adresse qu'aucun runtime ne configure. `scaleway_ipam_ip` est donc hors de portée ici. |
| LB et public gateway Scaleway | Réellement absents. Les deux vrais manques que nos modules rencontrent. Depuis la 0.7.3 ils refusent au moins lisiblement — `501` dans le dialecte du SDK au lieu du `404` en texte brut de net/http, que le SDK Scaleway jetait pour son content type (notre issue #74). |
| Type de volume racine Scaleway | Aucun `root_volume { volume_type }` n'est écrivable : le provider 2.79+ refuse `b_ssd`, et `sbs_volume` planifie éternellement car l'émulateur l'écrase. L'honorer enverrait le provider sur `block/v1`, non monté. Mesuré ici, c'est devenu la limite documentée en amont et son issue #8. |
| Résolution d'image par nom | Le catalogue est fixe, et la 0.7.0 applique le filtre `image_names` : un nom publié par un pipeline de build ne correspond à rien — des deux côtés. Les tfvars Scaleway épinglent `image_id` ; ceux d'Outscale pointent `image_name` sur une entrée du catalogue, ce qui exerce la recherche sans prétendre résoudre notre propre image. |

Trois choses ont quitté cette liste. `outscale_volume_link` en 0.6.0, qui a monté
le filtre `LinkVolumeVmIds` dont dépend son attente. `data.outscale_images` en
0.7.0, qui ne fait plus segfaulter le provider — la voie Outscale résout donc son
image par la data source plutôt que par un id épinglé, ce qui exerce la forme
`images[0]` que le module portait comme une hypothèse non vérifiée. Et
`CreateTags` en 0.7.1 (notre issue #99) : la table de préfixes en tenait quatre
contre seize que le pack frappait, si bien que taguer un `igw-` ou un `rtb-`
était refusé sur une ressource que l'émulateur venait de créer. La fixture tague
maintenant six types plutôt que de remettre les trois qu'elle avait retirés — une
table qui a pris du retard une fois mérite d'être exercée sur plus que la ligne
qui l'a attrapée.
