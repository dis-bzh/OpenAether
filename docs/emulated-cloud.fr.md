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
que le `plan` : le module crée toujours une public gateway et des réservations
IPAM côté Scaleway, et côté Outscale des security groups, des IP publiques, un
internet service, un NAT service, des route tables et des load balancers — que
l'émulateur ne sert pas. Le root déclarant un backend S3 partiel, la voie y
dépose un `*_override.tf` de backend local et le retire en sortant.

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

Trois attributs de production que cette voie ne peut pas porter aujourd'hui, tous
consignés dans [`backlog.md`](backlog.md) : le type de volume racine Scaleway,
`outscale_volume_link`, et `data.outscale_images` — qui fait segfaulter le
provider Outscale, parce que `data_source_outscale_images.go:289` déréférence
`*image.BlockDeviceMappings` sans garde nil alors que l'émulateur omet ce champ.
