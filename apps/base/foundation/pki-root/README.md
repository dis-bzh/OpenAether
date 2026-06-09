# OpenBao root — Procédure d'unseal et stockage recovery keys

**OpenAether 0.5.0 sprint 0** — `apps/base/foundation/pki-root/`

## Rôle

OpenBao root est un OpenBao "racine" **non-HA (1 répl)** scellé **Shamir 3-of-5**.
Il ne stocke **aucune donnée applicative** : il sert **uniquement** de seal
`transit` pour auto-unsealer le workload OpenBao (3 répl HA dans
`apps/base/foundation/vault/`).

```
┌──────────────────────────────────────────────────────────────────┐
│ Cluster management (Talos k8s v1.35)                             │
│                                                                  │
│  OpenBao root ─── transit wrap ──▶  OpenBao workload (3 répl)   │
│  (1 répl, shamir)                          (HA, auto-unsealed)  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Auto-unseal du root par le Job bootstrap (mode normal)

> **Validé localement (Talos) : 26/26 tests e2e passants.**

En fonctionnement nominal, le **Job bootstrap consolidé**
(`bootstrap/00-bootstrap-job.yaml`, ArgoCD PostSync, idempotent) gère TOUT :
init Shamir 5/3 → stockage des unseal keys dans le Secret
`openbao-root-recovery` → unseal du root (3 clés) → transit → seal token
workload → init raft workload. **Au redémarrage du root**, relancer le Job
suffit : il lit les unseal keys depuis le Secret et re-unseal automatiquement
(c'est ce que fait ArgoCD au prochain sync, ou manuellement :
`kubectl delete job openbao-bootstrap -n foundation-pki-root && kubectl apply -k apps/base/foundation/pki-root`).

⚠️ **Sécurité** : le Secret `openbao-root-recovery` (unseal keys + root token)
vit dans le cluster pour permettre l'auto-recovery sprint 0. C'est une
**simulation** du root (cf. décision archi : le root sera remplacé par
HSM/KMS sprint 1+). Pour un vrai air-gap, supprimer ce Secret après init et
n'utiliser que les parts offline ci-dessous (unseal manuel).

## Procédure d'unseal manuel (si Secret recovery supprimé / air-gap)

### 1. Récupérer 3 unseal keys (sur 5)

Stockage des 5 parts Shamir 3-of-5 (créées à l'`init` par le Job bootstrap,
champ `unseal_keys` du Secret — clés Shamir, pas "recovery" au sens auto-unseal) :

| Share | Stockage physique | Propriétaire |
|-------|-------------------|--------------|
| 1 | USB chiffré (LUKS, age) dans coffre-fort ignifugé bureau | Vincent |
| 2 | USB chiffré dans coffre bancaire Paris | Vincent |
| 3 | Papier scellé dans enveloppe notariale (optionnel HSM) | Notaire |
| 4 | USB chiffré chez Vincent, coffre maison campagne | Vincent |
| 5 | Papier scellé chez associé de confiance | Associé |

### 2. Unsealer le root (API HTTP — pas de CLI `bao` requis)

> NB : l'image `openbao/openbao` défaut le CLI sur HTTPS. Les listeners sprint 0
> sont en HTTP (`tls_disable=1`). On utilise donc l'API HTTP directement.

```bash
kubectl port-forward -n foundation-pki-root openbao-pki-root-0 8200:8200 &
B=http://127.0.0.1:8200

# État
curl -s $B/v1/sys/seal-status | jq '{sealed,initialized}'

# Unseal avec 3 des 5 parts (une à la fois)
curl -s -X PUT -d '{"key":"<part1>"}' $B/v1/sys/unseal | jq .sealed
curl -s -X PUT -d '{"key":"<part2>"}' $B/v1/sys/unseal | jq .sealed
curl -s -X PUT -d '{"key":"<part3>"}' $B/v1/sys/unseal | jq .sealed   # → false
```

### 3. Vérifier que le workload auto-unseal fonctionne

```bash
# Le workload doit être unsealed via transit (sealed=false)
kubectl exec -n foundation-vault openbao-0 -- \
  wget -qO- http://127.0.0.1:8200/v1/sys/seal-status | jq '{sealed,type}'
# {"sealed": false, "type": "transit"}
```

## Rotation des recovery keys (annuelle)

```bash
# Forward root token (post-unseal)
kubectl exec -n foundation-pki-root openbao-pki-root-0 -- \
  bao login <root-token>

# Rotate
kubectl exec -n foundation-pki-root openbao-pki-root-0 -- \
  bao operator generate-root -format=json
# Sortie: nouveau root token + 5 nouvelles recovery keys
# → mettre à jour Secret openbao-root-recovery (Job idempotent)
# → distribuer les nouvelles shares (5 USB/papier)
# → détruire les anciennes shares (shred USB, brûlage papier)
```

## Procédure DR (root complètement perdu)

Si le root OpenBao est perdu (PVC corrompu, cluster détruit sans backup) :

1. **Re-créer le root** depuis la définition apps/base/foundation/pki-root/
   (GitOps ArgoCD).
2. **Réinit** : Job bootstrap `00-bootstrap-job` (idempotent : vérifie
   `/v1/sys/seal-status .initialized` → false, donc init). Le Job
   redéploie transit, key, role, seal token workload, init raft workload.
3. **Le workload auto-unsealed** au prochain cycle de vie des pods (ou
   unseal manuel via Shamir 3-of-5 directement sur workload — plan B
   documenté dans `apps/base/foundation/vault/README.md`).

## Backup recommandé (hebdomadaire)

```bash
# Snapshot raft root (rarement nécessaire car root n'a que la config)
kubectl exec -n foundation-pki-root openbao-pki-root-0 -- \
  bao operator raft snapshot save /tmp/root.snap

# Récupération
kubectl cp foundation-pki-root/openbao-pki-root-0:/tmp/root.snap ./root-$(date +%F).snap

# Restore
kubectl exec -i -n foundation-pki-root openbao-pki-root-0 -- \
  bao operator raft snapshot restore - < ./root-YYYY-MM-DD.snap
```

## Métriques d'alerte (cf. prometheusrule.yaml)

- `OpenBaoRootSealed > 5min` → critical
- `OpenBaoRootRestarting > 3/15min` → warning

## Migrations futures

Le root est isolé dans son propre ns + deployment. Migration future
facile sans toucher au workload :

| Sprint | Cible | Migration |
|--------|-------|-----------|
| 1.0 | OVHcloud Shared HSM (PKCS#11) | seal `shamir` → seal `pkcs11` (config.hcl) |
| 1.0+ | OVHcloud KMS / Scaleway KMS | via wrapper ou seal `transit` vers root KMS-dédié |
| 1.0+ | Multi-région DR | 2 root (1 SCW fr-par + 1 OVH gra) + seal `transit` workload vers les 2 |

## Limitations connues sprint 0

- TLS désactivé (`tls_disable = 1`) sur listener root. **À activer
  sprint 1** via cert-manager + openbao-server-tls.
- L'init + l'unseal + la config transit + l'init raft workload se font via
  un **unique Job consolidé** `bootstrap/00-bootstrap-job.yaml` (ArgoCD
  PostSync, idempotent, API HTTP — image `alpine/k8s` car `kubectl`+`jq`+`curl`
  absents de l'image openbao).
- Root pod redémarre = **re-unseal automatique** par re-run du Job (lit le
  Secret `openbao-root-recovery`). En mode air-gap (Secret supprimé), cérémonie
  Shamir 3-of-5 manuelle requise.
- `disable_mlock` retiré (obsolète OpenBao 2.x) + capability `IPC_LOCK` retirée.
- `seal "transit"` : le token est fourni via env `VAULT_TOKEN` (le wrapper
  `entrypoint.sh` le lit depuis `/bao/seal/token`) — `token_path` n'existe PAS.
- raft : `podManagementPolicy: Parallel` + `api_addr`/`cluster_addr` en **DNS
  stable** (pas POD_IP) — sinon pas d'élection de leader après restart.
