# Jour 1 — initialisation admin après `task up` (management)

🇬🇧 [English version](admin-access.en.md)

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

## 3ter. Planifier le snapshot etcd (opérateur)

Le snapshot etcd est un **raccourci de RTO** : le contenu du cluster est
reconstruit par Flux, mais quelques objets ne vivent QUE dans etcd (Secrets
écrits par des Jobs, bindings de PVC…). `task etcd-snapshot` le fait à la
demande ; rien ne le déclenchait périodiquement.

```bash
# 03:40 chaque jour — chemin ABSOLU obligatoire, la sortie part par mail
40 3 * * * /chemin/vers/OpenAether-infra/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/id_ed25519-ovh-openaether-dev >> /var/log/openaether-etcd-snapshot.log 2>&1
```

Le wrapper existe parce que la task seule n'est pas utilisable en cron :
- cron démarre avec un `PATH` minimal, or les outils sont éparpillés
  (`task`/`talosctl` dans `/usr/local/bin`, `tofu`/`aws` dans `/snap/bin`) ;
- les credentials viennent de `.env.sh`, que cron n'hérite pas ;
- **`task etcd-snapshot` ouvre les tunnels SSH et ne les referme pas** — en
  cron ils s'accumuleraient ; le wrapper les ferme même en cas d'échec ;
- un verrou `flock` évite qu'un snapshot lent croise le suivant.

Il tourne sur la machine qui détient le dépôt ET les credentials. Un échec sort
en code non nul avec un message horodaté — de quoi être vu par cron ou un
superviseur.

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
- Credentials : Grafana → `bao kv get secret/grafana/admin` ; Zitadel → console
  d'init.
- **OpenBao — ne PAS utiliser le root token au quotidien.** Il n'expire pas, ne
  se révoque pas utilement, et n'apparaît dans aucun audit sous un nom d'humain.
  Deux policies nominatives sont créées au bootstrap :

  ```bash
  # accès humain, 8 h, tracé sous un nom
  bao token create -policy=openaether-admin  -ttl=8h -display-name=prenom
  bao token create -policy=openaether-reader -ttl=8h -display-name=prenom   # lecture seule
  ```

  `openaether-admin` couvre l'exploitation courante (secrets, PKI, policies,
  auth, montages, baux) mais **refuse explicitement** sceller, `step-down`,
  rekey et rotation de la clé. Ces gestes de dernier recours restent au root
  token escrowé hors ligne : ils deviennent délibérés, pas routiniers.
- ⚠️ si ton IP publique change : mettre à jour `admin_ip` dans le tfvars puis
  `task infra` (sinon bastion injoignable — tunnels 0/N).

## 4bis. SSO Grafana via Zitadel (OIDC)

Grafana accepte désormais l'authentification Zitadel **en plus** de son admin
local. Le formulaire local reste actif volontairement : c'est le filet si le SSO
est cassé ou pas encore configuré. Ne le désactiver (`disable_login_form`)
qu'une fois le SSO éprouvé.

✅ **Déjà fait sur le cluster OVH du 2026-07-28** (projet `OpenAether`, rôle
`grafana-admin`, application web `Grafana`, `secret/grafana/oidc` seedé). Les
étapes ci-dessous valent pour un NOUVEAU cluster.

⚠️ **Le scope des rôles est indispensable** : sans
`urn:zitadel:iam:org:projects:roles` dans `scopes`, Zitadel n'émet aucun claim
de rôles et tous les comptes restent `Viewer`. Mesuré en réel. Il est désormais
dans `apps/base/observability/grafana.yaml`.

À faire côté Zitadel (console ou API), une seule fois :

1. Projet « OpenAether » → **Application** de type **Web**
2. Méthode d'authentification **Code** (PKCE) + client secret
3. Redirect URI : `https://grafana.openaether.local/login/generic_oauth`
   Post-logout : `https://grafana.openaether.local/login`
4. Pour piloter les rôles : créer un rôle projet `grafana-admin`, l'assigner, et
   activer « User Info inside ID Token »
5. Reporter les identifiants :

```bash
bao kv put secret/grafana/oidc client-id=… client-secret=…
```

Tant que ce chemin n'est pas seedé, **Grafana démarre quand même** (les
variables d'environnement OIDC sont `optional`) : seul le bouton Zitadel est
inopérant. C'est délibéré — un SSO non configuré ne doit pas rendre Grafana
inaccessible.

⚠️ À vérifier au premier déploiement : la **structure** du claim de rôles. Le
nom (`urn:zitadel:iam:org:project:roles`) est confirmé par la doc Zitadel, mais
sa forme dépend de la configuration de l'application :

```bash
curl -H "Authorization: Bearer <token>" https://zitadel.openaether.local/oidc/v1/userinfo
```

Ajuster `role_attribute_path` dans `apps/base/observability/grafana.yaml` si
besoin. `role_attribute_strict: false` fait retomber sur `Viewer` en cas de
non-correspondance, plutôt que de refuser l'accès.

Le chemin réseau Grafana → Zitadel (`:8080`, échange du code puis
`/oidc/v1/userinfo`) est ouvert des deux côtés dans les CiliumNetworkPolicy —
sans quoi la connexion échouerait en « operation not permitted », sans autre
trace qu'un timeout côté Grafana.

## 4ter. Tests NAVIGATEUR — ce qui ne peut pas être validé autrement

Tout le reste du socle se vérifie en ligne de commande. Ces trois points-là,
non : ils exigent un vrai navigateur, parce qu'ils reposent sur des redirections
et des cookies.

### Prérequis BLOQUANT — signer l'intermediate PKI

Rien n'est accessible par la gateway tant que l'étape 2 n'est pas faite : le
listener HTTPS reste `Programmed=False` et le certificat `openaether-tls`
échoue sur

```
Vault failed to sign certificate: no default issuer currently configured
```

C'est attendu : la PKI d'OpenBao n'a pas d'intermediate signé. Vérifier :

```bash
kubectl get gateway -n services-gateway openaether-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

Les deux doivent afficher `True`. Sinon, reprendre l'étape 2.

### Ouvrir l'accès

```bash
ssh -i <clé bastion> -L 8443:172.16.12.241:443 bastion@<IP-bastion> -N
# /etc/hosts :
# 127.0.0.1 grafana.openaether.local zitadel.openaether.local vault.openaether.local longhorn.openaether.local
```

Importer la **root CA** dans le navigateur, sinon chaque page lèvera un
avertissement de certificat qui masquera les vrais symptômes.

### Test 1 — le SSO Grafana (le seul point vraiment ouvert)

L'application Zitadel, le rôle `grafana-admin` et le secret sont déjà en place.
Sur `https://grafana.openaether.local:8443` :

1. le bouton **« Sign in with Zitadel »** est présent → la config est chargée ;
2. il redirige vers Zitadel et la connexion aboutit → `client_id`/`client_secret`
   et l'URI de redirection sont bons ;
3. **le point à trancher** : le rôle obtenu. Menu *Administration → Users*.
   - compte porteur de `grafana-admin` en **Admin** → le mapping fonctionne,
     plus rien à faire ;
   - tout le monde en **Viewer** → le claim de rôles n'est pas celui attendu.
     Zitadel émet deux formes de nom selon le contexte ; on a retenu la forme
     non préfixée. Pour trancher, décoder le token :

     ```bash
     # depuis la page Grafana, récupérer l'access token (outils dev → réseau)
     curl -H "Authorization: Bearer <token>" \
       https://zitadel.openaether.local:8443/oidc/v1/userinfo | jq 'keys'
     ```

     Si la clé est `urn:zitadel:iam:org:project:<ID>:roles`, reporter cet ID
     dans `role_attribute_path` (`apps/base/observability/grafana.yaml`).
     La STRUCTURE, elle, est confirmée : un objet dont les clés sont les rôles,
     donc `keys()` reste correct.

⚠️ Le formulaire de connexion local reste actif : c'est le filet si le SSO
échoue. Ne le désactiver (`disable_login_form`) qu'une fois ce test passé.

### Test 2 — l'UI OpenBao derrière la gateway

`https://vault.openaether.local:8443` doit afficher l'écran d'unseal/login.
C'est ce qui valide le `DestinationRule` en `credentialName` : la gateway parle
désormais en TLS **vérifié** à OpenBao. Une page blanche ou un 503 avec, côté
OpenBao, un log `TLS handshake error … client sent an HTTP request to an HTTPS
server`, signifierait que le DestinationRule n'est pas pris en compte.

### Test 3 — l'ingress PUBLIC (hors tunnel)

Les deux tests ci-dessus passent par la VIP privée. Pour valider le chemin
public de bout en bout, viser l'IP du LB applicatif **sans tunnel** :

```bash
curl -kv --resolve grafana.openaether.local:443:<IP-app-lb> \
  https://grafana.openaether.local/login
```

Le raccordement LB → nodePorts 30080/30443 est déjà vérifié côté
infrastructure ; ce test confirme la traversée applicative complète.

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

Attendu pour un enfant sain avec le profil `workload` : **19/19 Kustomizations**
(18 du profil + la racine posée par le scaffold). Ce compte **bouge à chaque
brique ajoutée au DAG** — il valait 17/17 avant le 2026-07-27, puis 18/18. Ne
pas le lire comme une régression : le vérifier avec
`python3 scripts/pick.py vault eso certs gateway` (côté apps), qui annonce le
nombre de Kustomizations retenues.

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
