# purge-orphans — filet de sécurité pour ressources cloud orphelines

Scripts de **dernier recours**, à n'utiliser que lorsque des ressources d'un
cluster survivent à son contrôleur : cluster de management détruit avant ses
enfants CAPI, `edge-down` en échec, ou state OpenTofu perdu. Dans tous les
autres cas, passer par `task fleet-down` / `task edge-down` / `task destroy`,
qui suppriment proprement **et** mettent le state à jour.

Ces scripts parlent directement à l'API du provider : ils ignorent le state
OpenTofu et ne le mettent pas à jour. Ne les lancer que sur un compte dont on
sait ce qu'il doit rester (ils ciblent TOUT le projet, pas un cluster précis).

```bash
source .env.sh
python3 scripts/ops/purge-orphans/ovh.py              # dry-run : liste les cibles
python3 scripts/ops/purge-orphans/ovh.py --apply      # supprime
python3 scripts/ops/purge-orphans/outscale.py --apply
```

Ordre de suppression imposé par les dépendances (déjà encodé) :
serveurs → load balancers → IP publiques → routeurs/route tables →
internet gateway → security groups → subnets → réseau.

Les 409/`ResourceConflict` sont normaux au premier passage (ports ou NIC pas
encore libérés) : **relancer** jusqu'à ce que plus rien ne soit supprimé.
Un réseau récalcitrant garde souvent des ports DHCP résiduels ; les supprimer
d'abord (le script OVH le fait).

Scaleway : pas de script — l'API se manipule en deux appels
(`POST /servers/<id>/action {"action":"terminate"}`, puis `DELETE /lb/v1/.../lbs/<id>?release_ip=true`),
cf. `docs/backlog.md` pour l'historique de l'incident qui a motivé ces outils.
