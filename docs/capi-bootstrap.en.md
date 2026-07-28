# Bootstrapping a management cluster with CAPI (pivot from local)

🇫🇷 [Version française](capi-bootstrap.md)

Procedure **validated end-to-end on 2026-07-28** on Scaleway: a throwaway
cluster creates the management, the management creates its own child, then the
management takes ownership of its own CAPI objects and the throwaway cluster is
destroyed.

This is an **optional path**, alongside OpenTofu — not a replacement. See
`backlog.md` § "Piste architecture" for the trade-off.

```
   local (Talos/Docker)  ──CAPI──▶  mgmt-capi (Scaleway)
        clusterctl init                  │
                                         └──CAPI/GitOps──▶  edge-capi
        ── clusterctl move ──▶  mgmt-capi manages itself
        task local-down            (the local cluster disappears)
```

## Prerequisites

| What | Check |
|---|---|
| Reachable Docker engine | `docker info` — on Windows, start Docker Desktop **and** enable WSL integration |
| `clusterctl` matching the CoreProvider | `clusterctl version` → must equal the version in `core-providers.yaml` (v1.13.2) |
| Talos image published at the provider | see `talos-image/`; Scaleway instance images are **per zone** |
| Provider credentials | `.env.sh` |

## 1. Throwaway cluster

```bash
task local-up          # 3 CP + 3 workers, Talos on Docker
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
```

Check **egress** before going further — without it the provider controller will
create nothing:

```bash
kubectl run egress-test --image=curlimages/curl:8.11.1 --restart=Never --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://api.scaleway.com/instance/v1/zones
```

## 2. CAPI on the throwaway cluster

Use `clusterctl init`, NOT our bricks: the operator goes through a `HelmRelease`
(so cluster egress + cert-manager + Flux) — needlessly heavy for a cluster you
are about to throw away. `clusterctl init` downloads from your workstation.

⚠️ **Versions must match our bricks exactly**, otherwise `clusterctl move` will
reject the target.

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

## 3. Create the management cluster

The template is the same one used for a child cluster. Outside Flux, render it
with `flux envsubst`, which understands `${VAR:=default}` (plain `envsubst`
does not).

```bash
export CLUSTER_NAME=mgmt-capi CP_REPLICAS=1 WORKER_REPLICAS=1 \
       K8S_VERSION=v1.35.3 TALOS_VERSION=v1.13 \
       SCW_IMAGE_NAME=talos-scaleway-amd64-v1.13.4 SCW_ZONE=fr-par-1 \
       SCW_REGION=fr-par SCW_INSTANCE_TYPE=DEV1-L \
       SCW_PROJECT_ID="$SCW_DEFAULT_PROJECT_ID"

kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/templates/cluster-talos-scaleway \
  | flux envsubst | kubectl apply -f -
```

Grab its kubeconfig once `Cluster` reaches `Provisioned`:

```bash
kubectl -n capi-clusters get secret mgmt-capi-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > mgmt-capi.kubeconfig
```

## 4. Equip the management cluster

Exactly what a parent does for a child, but driven from your workstation.

```bash
helm --kubeconfig mgmt-capi.kubeconfig upgrade --install cilium cilium/cilium \
  --version 1.19.2 -n kube-system -f <CAPI child values> --wait

kubectl --kubeconfig mgmt-capi.kubeconfig apply --server-side --force-conflicts \
  -f ../OpenAether-apps/apps/base/cluster-api-clusters/flux-gotk/gotk-components.yaml

CHILD_NAME=mgmt-capi CHILD_PROFILE=management-capi CHILD_BRANCH=<branch> \
  kubectl kustomize ../OpenAether-apps/apps/base/cluster-api-clusters/child-gitops \
  | flux envsubst | kubectl --kubeconfig mgmt-capi.kubeconfig apply -f -
```

Then seed its operator secrets (`scaleway-capi-credentials` in `capi-clusters`,
the `*-substitutes` ones in `flux-system`) and it will deploy its own children
on its own.

⚠️ **Two management clusters must never read the same `apps/clusters`**: they
would fight over the same CAPI CRs. Isolate by branch (`CHILD_BRANCH`) or by
path.

## 5. The pivot

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig
clusterctl move --to-kubeconfig=mgmt-capi.kubeconfig -n capi-clusters
task local-down
```

Verify self-management:

```bash
KUBECONFIG=mgmt-capi.kubeconfig clusterctl describe cluster mgmt-capi -n capi-clusters
```

## The three pitfalls, all hit for real

### `clusterctl move` rejects a target equipped by our operator

```
failed to check providers in target cluster: [provider bootstrap-talos not
found in the target cluster, ...]
```

`cluster-api-operator` and `clusterctl` maintain **two different inventories**:
the former under `operator.cluster.x-k8s.io`, the latter under
`clusterctl.cluster.x-k8s.io/Provider`. A cluster equipped by the operator has
the CRD but no entries.

**Fixed in the repo** — the `clusterctl-inventory` brick, an automatic companion
of `cluster-api-providers`. Its versions must stay aligned with
`core-providers.yaml` / `infra-providers.yaml`.

⚠️ **`--dry-run` does NOT perform this check.** It passes completely; the
failure only surfaces on the real move.

### Machines never bind to their nodes

```
cannot start the move operation while ... is still provisioning the node
```

Talos nodes have **no `spec.providerID`**: there is neither a
cloud-controller-manager nor `--provider-id` on the kubelet. CAPI therefore
cannot bind `Machine` to `Node`, and Machines stay in `Provisioned`.

**This defect affects the whole fleet**, not just this test — `edge-1` and
`edge-2` are in the same state. Consequences beyond the pivot:
`MachineHealthCheck` cannot work, and deleting a Machine does not drain its
node.

Immediate workaround (this is what unblocked the pivot): copy each Machine's
`providerID` onto its Node.

```bash
kubectl -n capi-clusters get machines -o json \
  | jq -r '.items[] | "\(.metadata.name) \(.spec.providerID)"' \
  | while read M PID; do
      # resolve the instance name from the UUID, then:
      kubectl --kubeconfig <child> patch node "$NAME" --type=merge \
        -p "{\"spec\":{\"providerID\":\"$PID\"}}"
    done
```

⚠️ The node name **does not follow** the Machine name on the control plane
(`mgmt-capi-cp-clmwj` → node `mgmt-capi-cp-cqqtl`): resolve through the instance
UUID, never by name.

The real fix is a per-provider CCM, or `provider-id` injected into the kubelet.
Open work item, see `backlog.md`.

### Local cluster host ports on Windows

```
ports are not available: exposing port TCP 127.0.0.1:51000 -> 127.0.0.1:0:
/forwards/expose returned unexpected status: 500
```

Hyper-V reserves blocks of 100 ports above 49152, and those blocks move across
reboots. **Fixed**: `talos_api_port_base` (default 41000, below the dynamic
range). Diagnose a machine with
`netsh.exe int ipv4 show excludedportrange protocol=tcp`.

## Teardown

Order matters: the management owns its children's CRs.

```bash
kubectl --kubeconfig mgmt-capi.kubeconfig -n capi-clusters delete cluster edge-capi
kubectl --kubeconfig mgmt-capi.kubeconfig -n capi-clusters delete cluster mgmt-capi   # deletes itself
```

⚠️ A self-managed cluster **cannot finish deleting itself**: it destroys its
workers, then its control plane, and the controller dies with it. Provider-side
resources survive. For a clean teardown, pivot back to a throwaway cluster
(`clusterctl move` in reverse) — or delete the instances provider-side and purge
the CRs afterwards.

If a test branch served as the source, delete it **after** the teardown:
otherwise the clusters are left pointing at a source that no longer exists.
