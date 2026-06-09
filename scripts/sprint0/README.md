# OpenAether 0.5.0 — Tests e2e Sprint 0

## Objectif

Valider que la chaîne complète **OpenBao root (Shamir 3-of-5) +
workload (HA 3 répl, seal transit)** fonctionne end-to-end sur le
cluster Talos local (Talos docker 3 CP + 2 workers).

## Pré-requis

1. Cluster Talos local up via `task local-test`
2. Kubeconfig chargé : `export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig`
3. Manifests sprint 0 appliqués (cf. Sprint 0 PR description)

## Usage

```bash
# En local (depuis la racine du repo)
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
bash scripts/test-sprint0-openbao.sh
```

## Tests couverts (6)

| # | Test | Validation |
|---|------|------------|
| 1 | Root unsealed + transit engine | `bao status` Sealed=false, `bao secrets list` contient `transit/`, clé `aether-workload` présente |
| 2 | Workload unsealed + raft 3/3 + KV + auth k8s | `bao status` Sealed=false, raft 3 voters, secret/ mounted, kubernetes/ mounted |
| 3 | Auth k8s workload → transit wrap | SA openbao-workload peut s'authentifier sur root via role workload-unseal |
| 4 | Restart workload → auto-unseal | Suppression pod openbao-0 → nouveau pod auto-unsealed via transit, data raft préservée |
| 5 | Restart root → Shamir unseal requis | Suppression pod root → nouveau pod scellé, Shamir 3-of-5 requis (procédure manuelle documentée) |
| 6 | NetworkPolicy sanity | CCNP allow-dns/allow-kube-api + CNP openbao présents |

## Résultats attendus (sprint 0)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  test-sprint0-openbao: 14/14 passed, 0 failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Test 5 peut afficher "warn" (root unsealed après restart si state
préservé dans PVC + Shamir auto-recovery via recovery keys dans
Secret openbao-root-recovery, mais en pratique le root ne s'auto-unseal
pas — c'est le comportement attendu).

## Troubleshooting

### "Root still sealed after 120s"

Le Job bootstrap 00-root-init n'a pas tourné ou a échoué. Vérifier :

```bash
kubectl logs -n foundation-pki-root -l app=openbao-bootstrap
kubectl get jobs -n foundation-pki-root
kubectl get secret openbao-root-recovery -n foundation-pki-root
```

### "Workload still sealed after 120s"

Le transit wrap échoue. Vérifier :

```bash
# 1. Root accessible
kubectl get pods -n foundation-pki-root -l app=openbao-pki-root
kubectl exec -n foundation-pki-root openbao-pki-root-0 -- bao status

# 2. Secret openbao-seal-token présent
kubectl get secret openbao-seal-token -n foundation-vault

# 3. Logs workload
kubectl logs -n foundation-vault openbao-0 | grep -E "transit|seal|unseal"
```

### "raft cluster has 3 voters" → FAIL

Le cluster raft n'a pas formé le quorum. Vérifier :

```bash
kubectl logs -n foundation-vault openbao-0 | grep -E "raft|retry_join|leader"
kubectl exec -n foundation-vault openbao-0 -- bao operator raft list-peers
```

## Intégration Taskfile

Ajouter à `Taskfile.yml` (snippet) :

```yaml
  test-sprint0:
    desc: "Run sprint 0 e2e tests (OpenBao root + workload)"
    dir: .
    env:
      KUBECONFIG: "{{.KUBECONFIG | default \"$PWD/infrastructure/opentofu-local/kubeconfig\"}}"
    cmds:
      - bash scripts/test-sprint0-openbao.sh
```
