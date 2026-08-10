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
task feint-plan  PROVIDER=scaleway     # plan du VRAI root cluster, sans credentials
task feint-apply PROVIDER=outscale     # cycle apply/destroy sur la fixture réduite
task feint-test                        # les deux providers, les deux voies
task feint-down
```

## Deux voies, parce qu'une seule ne peut pas faire les deux

**`feint-plan` — le vrai root `cluster`, plan seulement.** Vrais modules, vrai
provider, `envs/feint-<provider>.tfvars.example`. Impossible d'aller plus loin
que le `plan`, et ce qui l'en empêche tient désormais en une liste courte :

- **Scaleway** : le module crée toujours une public gateway et des réservations
  IPAM, aucune des deux n'est servie. Inchangé depuis la 0.5.0 — le pack
  Scaleway n'a pas bougé.
- **Outscale** : les load balancers, et rien d'autre. La 0.6.0 a fait passer le
  pack de 31 à 72 routes : security groups, IP publiques, internet service, NAT
  service, route tables et NICs fonctionnent tous ; `CreateLoadBalancer` reste
  décliné.

Le root déclarant un backend S3 partiel, la voie y dépose un `*_override.tf` de
backend local et le retire en sortant.

**`feint-apply` — `infrastructure/opentofu-feint/`, un vrai cycle CRUD.** Un root
séparé (même principe que `infrastructure/opentofu-local`) qui porte les mêmes
formes sur le sous-ensemble réellement servi : init → validate → plan → apply →
**second plan vide** → destroy, l'existence comme la disparition étant relues
depuis l'API et non depuis le state. Voir son
[README](../infrastructure/opentofu-feint/README.md).

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

Épinglé sur **Feint 0.6.0** (`scripts/dev/feint.sh`). Ce que cette voie ne peut
toujours pas porter, tout consigné dans [`backlog.md`](backlog.md) :

| Non exercé | Pourquoi |
|---|---|
| Load balancers Outscale | `CreateLoadBalancer` est décliné ; seul `ReadLoadBalancers` est monté. C'est la dernière chose entre cette voie et un apply complet du module Outscale. |
| LB, public gateway et réservations IPAM Scaleway | Non servis, et le pack Scaleway n'a pas changé en 0.6.0. |
| Type de volume racine Scaleway | Le module demande `sbs_volume` ; l'émulateur répond `b_ssd`, et le provider 2.80 refuse un `b_ssd` explicite. Honorer `sbs_volume` envoie le provider sur `block/v1`, qui n'est pas monté. |
| `data.outscale_images` | Fait segfaulter le provider : `data_source_outscale_images.go:289` déréférence `*image.BlockDeviceMappings` sans garde nil alors que le catalogue l'omet. Remonté en amont, toujours ouvert en 0.6.0 — d'où l'`image_id` épinglé dans les tfvars. |
| Tags sur route tables et internet services | `CreateTags` ne connaît que quatre préfixes d'identifiant (`vpc-`, `subnet-`, `i-`, `key-`) : taguer un `igw-` ou un `rtb-` est refusé sur une ressource qu'il vient de créer. Le module de production tague les deux. |

`outscale_volume_link` était dans cette liste et n'y est plus : la 0.6.0 monte le
filtre `LinkVolumeVmIds` dont dépend son attente.
