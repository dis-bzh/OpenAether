# Jour 1 — initialisation admin après `task up` (management)

Parcours **ordonné** des opérations manuelles post-déploiement. Chaque étape
renvoie au runbook détaillé de sa brique. Validé en conditions réelles
(Scaleway, 2026-07-25). Convention : `KC=infrastructure/opentofu/cluster/kubeconfig`.

## 1. Escrow (IMMÉDIAT — avant toute autre chose)

Trois secrets à mettre dans Bitwarden EU (puis à effacer des sorties locales) :

| Quoi | Où le lire | Pourquoi |
|---|---|---|
| Parts Shamir (5/3) + root token | `kubectl --kubeconfig $KC logs -n foundation-vault job/openbao-init` (aussi dans le Secret `openbao-recovery`, clés `root_token`/`unseal_key_*`) | unseal/DR OpenBao — la vérité doit être OFFLINE |
| Password restic des backups | `kubectl --kubeconfig $KC logs -n foundation-vault job/openbao-vault-bootstrap` (bloc `BEGIN RESTIC PASSWORD`, affiché UNE fois à la génération) | sans lui, les backups sont indéchiffrables le jour où OpenBao est perdu |
| Passphrase state (`TF_VAR_encryption_passphrase`) | déjà dans ton vault (prérequis du deploy) | tfstate + artifacts gpg + etcd-snapshot |

Runbooks : `OpenAether-apps/apps/base/foundation/vault/README.md` (rekey/DR),
`OpenAether-apps/apps/base/backup/README.md`.

## 2. Signer l'intermediate PKI (débloque le HTTPS)

Le Job bootstrap affiche le CSR (`BEGIN INTERMEDIATE CSR` dans ses logs).
Signer OFFLINE avec la root CA (Bitwarden), puis :

```bash
kubectl --kubeconfig $KC exec -i openbao-0 -n foundation-vault -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root_token> \
  bao write pki/intermediate/set-signed certificate=@- < intermediate-signed.pem
```

→ le Certificate `openaether-tls` passe Ready seul (retry cert-manager), le
listener 443 de la gateway se programme.
Runbook détaillé : `OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Activer les backups (brique backup, compagnon par défaut)

Les buckets doivent PRÉEXISTER (restic ne les crée pas) — un par destination,
providers différents en prod. Puis seed des destinations dans OpenBao :

```bash
bao kv put secret/backup/s3-primary endpoint="https://s3.fr-par.scw.cloud" \
  bucket="s3-openaether-scaleway-backups-dev" access_key=… secret_key=…
bao kv put secret/backup/s3-replica endpoint="https://s3.eu-west-par.io.cloud.ovh.net" \
  bucket="s3-openaether-ovh-backups-dev" access_key=… secret_key=…
```

Tant que non seedés : `ExternalSecret backup-restic-env` NotReady, CronJobs à
l'arrêt (by design). Test : `kubectl create job --from=cronjob/openbao-snapshot
test -n foundation-vault`. Détails : `OpenAether-apps/apps/base/backup/README.md`.

**`secret/backup/s3-primary` sert trois mécanismes** : dépôts restic, PITR CNPG
(`barmanObjectStore`) et backups de volumes Longhorn. Une seule destination à
seeder pour les trois.

**Loki a sa PROPRE destination** — volontairement séparée, pour ne pas lui
donner un accès en écriture au bucket des sauvegardes :

```bash
bao kv put secret/observability/loki-s3 \
  endpoint="https://s3.fr-par.scw.cloud" bucket="s3-openaether-scw-loki-dev" \
  accessKey=… secretKey=…
# En local, pour retrouver le comportement d'avant (MinIO interne) :
bao kv put secret/observability/loki-s3 \
  endpoint="http://minio.foundation-storage:9000" bucket="loki" \
  accessKey=… secretKey=…
```

⚠️ Tant que ce chemin n'est pas seedé, **Loki ne s'installe pas** (son
HelmRelease consomme ce Secret en `valuesFrom`). C'est voulu : mieux vaut un
échec visible qu'un Loki qui écrit silencieusement au mauvais endroit.

## 3bis. Quotas des comptes — à vérifier AVANT de déployer

Les quotas relevés le 2026-07-27 (lecture directe des API) :

| Provider | Instances | vCPU | RAM |
|---|---|---|---|
| **Outscale** | 10 | 20 | **40 Go** |
| **OVH** (projet utilisé) | **10** | 34 | 420 Go |
| Scaleway | non contraignant sur ce compte | | |

Ce que ça implique concrètement :

- **Outscale** : un management HA (3 CP + 3 workers + bastion) demande **44 Go**
  pour un plafond de 40. Le dépassement est **toléré à la création**, puis toute
  VM supplémentaire est refusée (`CreateVms → 10042 TooManyResources`). Aucun
  message dans le CR CAPI : l'`OscMachine` boucle en `VmNotReady` avec une IP
  réallouée sans fin, et il faut lire les logs du manager CAPOSC pour comprendre.
  → management HA Outscale **et** enfant Outscale sont exclusifs sur ce compte.
- **OVH** : 10 instances, soit management (7 avec le bastion) + **un seul**
  enfant (2). Pas de marge pour un second.

Pré-vol, avant tout `task up` ou activation d'un enfant :

```bash
source .env.sh
task preflight-quotas PROVIDER=outscale -- --add-vms 7 --add-cores 14 --add-ram-gb 44
```

Il sort en erreur si la topologie demandée dépasse — c'est exactement le
scénario qui a fait perdre deux déploiements.

## 4. Accès admin aux UIs (interface restreinte)

Exposition : gateway sur IP **privée VPC** (pool LB-IPAM) + SG bastion limité à
`admin_ip` → rien de public. Routes : `vault|grafana|zitadel|longhorn.openaether.local`.

- **Sans TLS (dépannage)** : `./scripts/ops/local-admin-portforward.sh`
  (port-forwards loopback-only).
- **HTTPS (après l'étape 2)** :
  ```bash
  ssh -i <clé bastion> -L 8443:<IP-gateway>:443 bastion@<IP-bastion> -N
  # IP gateway : kubectl get gateway -n services-gateway ; bastion : tofu output bastion_ip
  # /etc/hosts : 127.0.0.1 grafana.openaether.local vault.openaether.local zitadel.openaether.local longhorn.openaether.local
  ```
  → `https://grafana.openaether.local:8443` ; importer la root CA dans le
  navigateur pour la chaîne verte. (Alternative sans remap :
  `sshuttle -r bastion@<IP> 172.16.12.0/22`.)
- Credentials : Grafana → `bao kv get secret/grafana/admin` ; OpenBao UI →
  token dédié (`bao token create -policy=… -ttl=8h`, éviter le root au
  quotidien) ; Zitadel → console d'init.
- ⚠️ si ton IP publique change : mettre à jour `admin_ip` dans le tfvars puis
  `task infra` (sinon bastion injoignable — tunnels 0/N).

## 5. Clusters enfants CAPI (si surcouche piochée)

Avant d'activer un fichier dans `apps/clusters/` (cf. son README), poser les
secrets **hors git** :

```bash
kubectl --kubeconfig $KC create secret generic scaleway-capi-credentials -n capi-clusters \
  --from-literal=SCW_ACCESS_KEY=… --from-literal=SCW_SECRET_KEY=…
kubectl --kubeconfig $KC create secret generic <enfant>-substitutes -n flux-system \
  --from-literal=SCW_PROJECT_ID=…
```

Kubeconfig de l'enfant (généré par CAPI) :
```bash
kubectl --kubeconfig $KC get secret <enfant>-kubeconfig -n capi-clusters \
  -o jsonpath='{.data.value}' | base64 -d > <enfant>.kubeconfig && chmod 600 <enfant>.kubeconfig
```

⚠️ **Ne pas modifier les `values` Cilium d'un enfant déjà vivant.** L'upgrade
Helm déclenche un rollout du CNI sur un cluster souvent à 2 nœuds, sans marge :
en 2026-07-26 les deux edges en sont sortis dégradés (l'un avec le datapath
inter-nœuds définitivement cassé, `cilium-dbg status` → `Cluster health 0/2
reachable`). **Recréer l'enfant** (`task edge-down` puis réactiver son fichier)
est plus rapide et plus sûr que de réparer. Les valeurs correctes — dont
`cni.exclusive: false`, obligatoire dès qu'Istio ambient est pioché, et
`ipam.mode: kubernetes`, sans quoi les CIDR de pods sont taillés dans
`10.0.0.0/8` où vivent les sous-réseaux de nœuds — sont déjà dans
`apps/clusters/*.yaml` : un enfant créé aujourd'hui les reçoit au bootstrap.
`task apps-validate` vérifie cet alignement avant tout déploiement.

Attendu pour un enfant sain avec le profil `workload` : **18/18 Kustomizations**
(17 du profil + la racine posée par le scaffold). Le compte a changé le
2026-07-27 : `backup-openbao-identity` s'est ajouté (ConfigMap `CLUSTER_NAME`
qui préfixe les dépôts restic). Les runs antérieurs à cette date affichaient
17/17 — ce n'est pas une régression.

Vérifier l'état d'un enfant :
```bash
kubectl --kubeconfig <enfant>.kubeconfig get kustomization -n flux-system
# si `kubectl logs/exec` timeout alors que les nœuds sont Ready :
#   apiserver → kubelet:10250 est bloqué (security group) — cf. docs/backlog.md
```

## Checklist récapitulative

- [ ] Escrow Shamir + root token (Bitwarden)
- [ ] Escrow password restic (Bitwarden)
- [ ] Intermediate signé + `set-signed` (HTTPS opérationnel)
- [ ] Buckets backup créés + `secret/backup/s3-{primary,replica}` seedés
- [ ] Premier snapshot testé (job manuel → 2 destinations)
- [ ] Root CA importée dans le navigateur, tunnel testé
- [ ] (CAPI) secrets enfants posés, kubeconfig extrait
