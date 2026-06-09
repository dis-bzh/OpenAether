# OpenBao workload — Architecture & Runbook

**OpenAether 0.5.0 sprint 0** — `apps/base/foundation/vault/`

## Architecture

OpenBao workload = OpenBao "métier" du cluster management. 3 répl
raft (HA), seal `transit` (auto-unseal via root OpenBao).

```
                                  transit wrap (auto)
                                  <─────────────────────┐
                                                       │
┌─────────── root ───────────┐    transit unwrap      │
│ OpenBao root (1 répl)      │ ◄──────────────────────┘
│ ns: foundation-pki-root    │
│ seal: shamir 3-of-5        │
│ engine: transit            │
└────────────────────────────┘
                ▲
                │ JWT login role=workload-unseal
                │
┌─────────── workload ────────┐
│ OpenBao workload (3 répl)  │ ◄── clients: ESO, CSI, cert-manager,
│ ns: foundation-vault        │     istiod, Cilium GW, Prometheus
│ seal: transit (root)        │
│ storage: raft 3/3           │
│ engines: KV, PKI, audit     │
└─────────────────────────────┘
```

## Flux d'auto-unseal

1. Workload OpenBao démarre, lit `seal.token_path = /bao/seal/token`
   (Secret `openbao-seal-token` monté en volume).
2. Workload contacte le **root OpenBao** sur
   `openbao-internal.foundation-pki-root.svc.cluster.local:8200`,
   auth `kubernetes` role `workload-unseal`.
3. Root autorise (policy `workload-unseal` + role kubernetes binding SA).
4. Workload fait un transit-decrypt de la clé `aether-workload` →
   obtient la master key déchiffrée → s'auto-unseal.
5. Si le root est down ou le transit échoue → workload reste `Sealed: true`.
   Recovery: `kubectl exec` et unseal manuel via Shamir 3-of-5 (cf.
   `apps/base/foundation/pki-root/README.md` pour la procédure).

## Procédure unseal manuel (workload scellé, root OK)

```bash
# Récupérer 3 recovery keys depuis le root (via Secret openbao-root-recovery)
# Note: on ne peut PAS utiliser les recovery keys du root pour unseal le workload.
# Le workload n'a pas de Shamir (seal transit), donc il faut re-émettre un
# wrapping token via le root.

# Forward root
kubectl port-forward -n foundation-pki-root openbao-pki-root-0 18200:8200 &
export BAO_ADDR=http://127.0.0.1:18200

# Re-login root
ROOT_TOKEN=$(kubectl get secret openbao-root-recovery -n foundation-pki-root \
  -o jsonpath='{.data.root_token}' | base64 -d)
bao login "$ROOT_TOKEN" >/dev/null

# Re-trigger le Job 20 (workload-seal-token)
kubectl delete job openbao-workload-seal-token -n foundation-vault --ignore-not-found
# ArgoCD re-appliquera le Job au prochain sync, OU relancer manuellement
kubectl apply -f apps/base/foundation/pki-root/bootstrap/20-workload-seal-token-job.yaml

# Vérifier unseal
kubectl exec -n foundation-vault openbao-0 -- bao status | grep Sealed
# Sealed: false
```

## Procédure unseal manuel (workload scellé, root down)

1. Unseal le root d'abord (cf. `apps/base/foundation/pki-root/README.md`).
2. Puis appliquer la procédure ci-dessus (workload OK, root OK).

## Restart de la racine (rappel)

Le root redémarre (par ex. crash) = cérémonie Shamir 3-of-5 manuelle
requise. Le workload reste fonctionnel en `Sealed: true` (raft data
intacts), aucun impact sur les requêtes tant qu'on ne le restart pas.

## Rotation du wrapping token (recommandée 30j)

```bash
# Forward root
kubectl port-forward -n foundation-pki-root openbao-pki-root-0 18200:8200 &
export BAO_ADDR=http://127.0.0.1:18200

# Re-login root
ROOT_TOKEN=$(kubectl get secret openbao-root-recovery -n foundation-pki-root \
  -o jsonpath='{.data.root_token}' | base64 -d)
bao login "$ROOT_TOKEN" >/dev/null

# Re-trigger le Job 20 (régénère wrapping token)
kubectl delete job openbao-workload-seal-token -n foundation-vault --ignore-not-found
# ArgoCD re-applique au prochain sync OU kubectl apply manuel
```

## Métriques d'alerte (cf. prometheusrule.yaml)

- `OpenBaoWorkloadSealed > 2min` → critical
- `OpenBaoRaftNoLeader` → critical
- `OpenBaoTransitUnsealFailures` → warning
- `OpenBaoRaftLagHigh` → warning

## Limitations connues sprint 0

- TLS désactivé (`tls_disable = 1`) sur listener workload. **À activer
  sprint 1** via cert-manager + openbao-server-tls.
- Le `httproute.yaml` référence un Gateway pas encore déployé (Cilium GW
  arrive sprint 1+). Ne casse pas le sync ArgoCD mais la route sera
  `NoMatchingParent` jusqu'à la création du Gateway.
- Pas de backup S3 automatique (raft snapshot). **Sprint 4 obs:**
  ajouter barman CNPG + cron snapshot.
