# Amorcer un cluster de management par CAPI (pivot depuis le local)

🇬🇧 [English version](capi-bootstrap.md)

Procédure **validée de bout en bout le 2026-07-28** sur Scaleway : un cluster
jetable crée le management, le management crée son propre enfant, puis le
management récupère ses propres objets CAPI et le cluster jetable est détruit.

C'est un **chemin optionnel**, à côté d'OpenTofu — pas un remplacement. Voir
`backlog.md` § « Piste architecture » pour l'arbitrage.

```
   local (Talos/Docker)  ──CAPI──▶  mgmt-capi (Scaleway)
        clusterctl init                  │
                                         └──CAPI/GitOps──▶  edge-capi
        ── clusterctl move ──▶  mgmt-capi se gère lui-même
        task local-down            (le local disparaît)
```

## Prérequis

| Quoi | Vérification |
|---|---|
| Moteur Docker joignable | `docker info` — sous Windows, démarrer Docker Desktop **et** activer l'intégration WSL |
| `clusterctl` à la version du CoreProvider | `clusterctl version` → doit valoir la version de `core-providers.yaml` (v1.13.2) |
| Image Talos publiée chez le provider | cf. `talos-image/` ; l'image instance Scaleway est **par zone** |
| Identifiants provider | `.env.sh` |

## 1. Cluster jetable

```bash
task local-up          # 3 CP + 3 workers Talos sur Docker
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
```

Vérifier l'**egress** avant d'aller plus loin — sans lui, le contrôleur du
provider ne créera rien :

```bash
kubectl run egress-test --image=curlimages/curl:8.11.1 --restart=Never --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://api.scaleway.com/instance/v1/zones
```

## 2. CAPI sur le cluster jetable

On utilise `clusterctl init`, PAS nos briques : l'opérateur passe par une
`HelmRelease` (donc egress cluster + cert-manager + Flux) — inutilement lourd
pour un cluster qu'on va jeter. `clusterctl init` télécharge depuis le poste.

⚠️ **Les versions doivent être identiques à celles de nos briques**, sinon
`clusterctl move` refusera la cible.

```bash
clusterctl init --core cluster-api:v1.13.2 \
                --bootstrap talos:v0.6.12 \
                --control-plane talos:v0.5.13 \
                --infrastructure scaleway:v0.2.1

kubectl create namespace capi-clusters
kubectl -n capi-clusters create secret generic scaleway-capi-credentials \
  --from-literal=SCW_ACCESS_KEY="$SCW_ACCESS_KEY" \
  --from-literal=SCW_SECRET_KEY="$SCW_SECRET_KEY"
```

## 3. Créer le management

Le template est le même que pour un enfant : hors Flux, on le rend avec
`flux envsubst` (qui gère les défauts `${VAR:=…}`, contrairement à `envsubst`).

```bash
export CLUSTER_NAME=mgmt-capi CP_REPLICAS=1 WORKER_REPLICAS=1 \
       K8S_VERSION=v1.35.3 TALOS_VERSION=v1.13 \
       SCW_IMAGE_NAME=talos-scaleway-amd64-v1.13.4 SCW_ZONE=fr-par-1 \
       SCW_REGION=fr-par SCW_INSTANCE_TYPE=DEV1-L \
       SCW_PROJECT_ID="$SCW_DEFAULT_PROJECT_ID"

kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/templates/cluster-talos-scaleway \
  | flux envsubst | kubectl apply -f -
```

Récupérer son kubeconfig quand `Cluster` passe `Provisioned` :

```bash
kubectl -n capi-clusters get secret mgmt-capi-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > mgmt-capi.kubeconfig
```

## 4. Équiper le management

Exactement ce que le parent fait pour un enfant, mais depuis le poste.

```bash
helm --kubeconfig mgmt-capi.kubeconfig upgrade --install cilium cilium/cilium \
  --version 1.19.2 -n kube-system -f <values enfant CAPI> --wait

kubectl --kubeconfig mgmt-capi.kubeconfig apply --server-side --force-conflicts \
  -f ../OpenAether-apps/apps/base/cluster-api-clusters/flux-gotk/gotk-components.yaml

CHILD_NAME=mgmt-capi CHILD_PROFILE=management-capi CHILD_BRANCH=<branche> \
  kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/child-gitops \
  | flux envsubst | kubectl --kubeconfig mgmt-capi.kubeconfig apply -f -
```

Puis semer ses secrets opérateur (`scaleway-capi-credentials` dans
`capi-clusters`, les `*-substitutes` dans `flux-system`) et il déploie ses
propres enfants tout seul.

⚠️ **Deux managements ne doivent jamais lire le même `apps/clusters`** : ils se
disputeraient les mêmes CR CAPI. Isoler par branche (`CHILD_BRANCH`) ou par
chemin.

## 5. Le pivot

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
clusterctl move --to-kubeconfig=mgmt-capi.kubeconfig -n capi-clusters
task local-down
```

Vérifier l'autogestion :

```bash
KUBECONFIG=mgmt-capi.kubeconfig clusterctl describe cluster mgmt-capi -n capi-clusters
```

## Les trois pièges, tous rencontrés en réel

### `clusterctl move` refuse la cible équipée par notre opérateur

```
failed to check providers in target cluster: [provider bootstrap-talos not
found in the target cluster, ...]
```

`cluster-api-operator` et `clusterctl` tiennent **deux inventaires
différents** : le premier en `operator.cluster.x-k8s.io`, le second en
`clusterctl.cluster.x-k8s.io/Provider`. Un cluster équipé par l'opérateur a la
CRD mais aucune entrée.

**Corrigé dans le dépôt** — brique `clusterctl-inventory`, compagnon
automatique de `cluster-api-providers`. Ses versions doivent rester alignées
sur `core-providers.yaml` / `infra-providers.yaml`.

⚠️ **`--dry-run` ne fait PAS cette vérification.** Il passe intégralement ;
l'échec ne surgit qu'au move réel.

### Les Machines ne se relient pas à leurs nœuds

```
cannot start the move operation while ... is still provisioning the node
```

Les nœuds Talos n'ont **pas de `spec.providerID`** : il n'y a ni
cloud-controller-manager ni `--provider-id` sur le kubelet. CAPI ne peut donc
pas apparier `Machine` et `Node`, et les Machines restent en `Provisioned`.

**Ce défaut touche toute la flotte**, pas seulement ce test — `edge-1` et
`edge-2` sont dans le même état. Conséquences au-delà du pivot :
`MachineHealthCheck` ne peut pas fonctionner, et la suppression d'une Machine
ne draine pas son nœud.

Contournement immédiat (ce qui a débloqué le pivot) : recopier le
`providerID` de chaque Machine sur son Node.

```bash
kubectl -n capi-clusters get machines -o json \
  | jq -r '.items[] | "\(.metadata.name) \(.spec.providerID)"' \
  | while read M PID; do
      # retrouver le nom d'instance depuis l'UUID, puis :
      kubectl --kubeconfig <enfant> patch node "$NAME" --type=merge \
        -p "{\"spec\":{\"providerID\":\"$PID\"}}"
    done
```

⚠️ Le nom du nœud **ne suit pas** celui de la Machine côté control plane
(`mgmt-capi-cp-clmwj` → nœud `mgmt-capi-cp-cqqtl`) : passer par l'UUID de
l'instance, pas par le nom.

Le vrai correctif est un CCM par provider, ou `provider-id` injecté au kubelet.
Chantier ouvert, cf. `backlog.md`.

### Ports hôte du cluster local sous Windows

```
ports are not available: exposing port TCP 127.0.0.1:51000 -> 127.0.0.1:0:
/forwards/expose returned unexpected status: 500
```

Hyper-V réserve des blocs de 100 ports au-dessus de 49152, et ces blocs bougent
au redémarrage. **Corrigé** : `talos_api_port_base` (défaut 41000, hors plage
dynamique). Diagnostiquer une machine avec
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

## Teardown

L'ordre compte : le management détient les CR de ses enfants.

```bash
kubectl --kubeconfig mgmt-capi.kubeconfig -n capi-clusters delete cluster edge-capi
kubectl --kubeconfig mgmt-capi.kubeconfig -n capi-clusters delete cluster mgmt-capi   # se supprime lui-même
```

⚠️ Un cluster autogéré **ne peut pas terminer sa propre suppression** : il
détruit ses workers, puis son control plane, et le contrôleur meurt avec. Il
reste des ressources chez le provider. Pour un teardown propre, pivoter
d'abord vers un cluster jetable (`clusterctl move` en sens inverse) — ou
supprimer les instances côté provider et purger les CR ensuite.

Si une branche de test a servi de source, la supprimer **après** le teardown :
sinon les clusters restent sur une source introuvable.
