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

task feint-evidence PROVIDER=scaleway  # besoin d'Incus : apply sous un vrai runtime machine, puis
                                        # affiche ce qu'un baseline de la preuve de feint épinglerait (#151)
task feint-evidence-verify PROVIDER=scaleway  # vérifie une capture fraîche contre le baseline épinglé
```

## Trois voies, parce qu'une seule ne peut pas faire les trois

**`feint-plan` — le vrai root `cluster`, plan seulement.** Vrais modules, vrai
provider, `envs/feint-<provider>.tfvars.example`. Le script lui-même ne fait
toujours que planifier, mais les raisons qui l'arrêtaient là ont disparu depuis
Feint 0.12.0 — voir `feint-record` ci-dessous, qui applique désormais le
module provider de ce même root de bout en bout.

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
les plus appelées d'abord. En dessous, ceci exécute un vrai `tofu apply
-target=module.<provider>` sur le root cluster lui-même — le même root que
`feint-plan` se contente de planifier — à travers le proxy, et cet apply était
*censé* échouer au premier appel non servi.

**Fermé depuis Feint 0.12.0** (re-mesuré le 2026-08-31, les deux providers) :
*« every operation the client called is served by a pack »* — zéro appel non
servi, là où l'enregistrement 0.7.3 ci-dessous en listait trois. L'apply que
ceci mesure va maintenant jusqu'au bout sur les modules des deux providers, ce
qui prouve que le module provider du vrai root cluster peut être appliqué
contre l'émulateur, pas seulement planifié (voir `feint-plan` ci-dessus). Ce
qui échouait avant et où c'est parti est conservé dans « Manques connus »
ci-dessous, puisque c'est de l'histoire désormais, plus une limite actuelle.

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
| Type de volume racine Scaleway | Aucun `root_volume { volume_type }` n'est écrivable : le provider 2.79+ refuse `b_ssd`, et `sbs_volume` planifie éternellement car l'émulateur l'écrase. L'honorer enverrait le provider sur `block/v1`, non monté. Mesuré ici, c'est devenu la limite documentée en amont et son issue #8. Non re-vérifié sous 0.12.0. |
| Résolution d'image par nom, Outscale | Les tfvars Outscale pointent `image_name` sur une entrée fixe du catalogue, ce qui exerce le mécanisme de recherche sans résoudre un nom publié par notre propre pipeline — voir #150 pour ce qu'il faudrait. |

Six choses ont quitté cette liste. `outscale_volume_link` en 0.6.0, qui a monté
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

Trois de plus l'ont quittée en 0.12.0, mesuré le 2026-08-31, et cette table les
avait pourtant appelées permanents. **Load balancers Outscale** :
`CreateLoadBalancer` et `UpdateLoadBalancer` répondent maintenant 200 —
étiquetés ici « décliné volontairement... celui-là ne bougera pas » jusqu'à la
version qui l'a fait bouger. **Réservations IPAM Scaleway** :
`ipam/v1/API.BookIP` répond maintenant 200, pas le `501` que cette table
appelait un decline permanent. **LB et public gateway Scaleway** : chaque
route `lb/v1/ZonedAPI.*` que le module appelle (`CreateLB`, `CreateFrontend`,
`CreateBackend`, `AttachPrivateNetwork`…) répond maintenant 200 — les deux
manques que cette table appelait « réellement absents ». C'est l'apply propre
à `feint-record` (ci-dessus) qui a attrapé les trois : un apply du module
provider du vrai root cluster, les deux providers, allant jusqu'au bout avec
zéro appel non servi, là où la 0.7.3 s'arrêtait net au premier.

La moitié Scaleway de la résolution d'image par nom a fermé le même jour, pas
via une version de feint mais parce que `scripts/dev/feint.sh` enregistre
désormais une image sous le nom que demande
`envs/feint-scaleway.tfvars.example`, avant de planifier ou d'appliquer :
`data.scaleway_instance_image.talos`, code mort derrière un `image_id`
épinglé jusque-là, tourne maintenant pour de vrai, et `feint-plan` comme
`feint-record` le résolvent — le transcript de ce dernier montre le module
appelant `instance/v1/API.ListImages` et `GetImage` pour la première fois
(#150). Outscale non : ses tfvars pointent toujours `image_name` sur une
entrée du catalogue plutôt que sur quelque chose que cette voie a créé.
