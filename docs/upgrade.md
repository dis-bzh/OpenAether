# Upgrading a live cluster — Kubernetes and Talos

🇫🇷 [Version française](upgrade.fr.md)

> Building a cluster and keeping one are different claims. This is the second.
> Proven by hand on Scaleway, OVH and Outscale on 2026-08-13, HA topologies, every
> node upgraded **in place** rather than replaced.
>
> The unattended version of this same procedure is
> [`scripts/dev/staging-upgrade.sh`](../scripts/dev/staging-upgrade.sh), run
> weekly by `.github/workflows/staging.yml`. If the two ever disagree, the script
> is the one that gets run.

## The two facts everything here follows from

**A node's boot image is only the medium it was installed from.** After
`talosctl upgrade` the instance still reports the old image id, by design. Node
resources therefore carry `ignore_changes` on it — see
[`provider-contract.md` § Node image drift](../infrastructure/opentofu/modules/providers/provider-contract.md).
Without that, bumping `talos_version` would make a routine apply replace every
control plane at once and etcd would lose quorum.

**Talos supports a window of Kubernetes releases, not all of them.**
`cluster/versions-guard.tf` refuses an unsupported pair at plan time, and refuses
a Talos minor nobody has entered in its map rather than passing it silently. The
starting pair, the ending pair *and* the intermediate state all have to sit
inside the window, because the two move one at a time.

## Measure the interruption

Start this before anything, against the endpoint in the kubeconfig — never a
tunnel to one node, because that node is the one you are about to take away.

```bash
while :; do kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 \
  && echo ok || echo FAIL; sleep 1; done | tee probe.log
```

A clean run loses a few seconds while an apiserver restarts. The hand-run on
2026-08-13 lost three.

## Kubernetes first

It reboots nothing, so it isolates the control-plane roll from the node roll.

```bash
# edit kubernetes_version in envs/<role>-<provider>.tfvars, then
task infra ROLE=management PROVIDER=<p>
```

Talos reconciles the static pods and the kubelets; wait for every node to report
the new version before moving on. Note that this bypasses `talosctl upgrade-k8s`,
which sequences those components behind health checks — see `backlog.md`.

## Then Talos, in place

Bump `talos_version`, build the image for the new version (the node resources
ignore the image, but the *data source* still has to resolve), apply, then roll.

```bash
task talos-image PROVIDER=<p> VERSION=<new> ENSURE=1
# edit talos_version in the tfvars, then
task infra ROLE=management PROVIDER=<p>
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<key> -- --cp-only --upgrade
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<key> -- --workers-only --upgrade
```

`--upgrade` calls `talosctl upgrade`, which keeps the node's disk, identity and
etcd membership, drains it itself, and refuses a control-plane upgrade that would
cost etcd its quorum. One node at a time, health-gated between each, and
re-runnable: a node already on the target version is skipped. Control planes
first — a worker needs a healthy control plane to drain against.

### The roll stops on a node holding a database primary. That is correct.

`rolling-replace` refuses to reboot a node it could not drain, and a CNPG primary
**cannot be evicted**: its PodDisruptionBudget forbids it until a switchover has
happened, and on `local-path-retain` the instance could not move to another node
anyway. The roll sets `nodeMaintenanceWindow` on every CNPG Cluster for its
duration, which is necessary and not sufficient — measured on Scaleway
2026-08-14, where one worker held *two* primaries.

So this is a manual step today. When the roll stops naming a `*-db-N` pod:

```bash
# 1. which instance is primary, and where
kubectl get cluster -A -o custom-columns=NS:.metadata.namespace,\
NAME:.metadata.name,PRIMARY:.status.currentPrimary
kubectl get pod <primary> -n <ns> -o jsonpath='{.spec.nodeName}{"\n"}'

# 2. switch it to a healthy replica on a DIFFERENT node.
#    `task setup` installs the plugin (scripts/internal/install-kubectl-cnpg.sh,
#    pinned to the operator's minor); this line named it before anything did.
kubectl cnpg promote <cluster> <replica> -n <ns>

# 3. re-run the SAME command — nodes already on the target version are skipped
task rolling-replace PROVIDER=<p> KEY=~/.ssh/<key> -- --workers-only --upgrade
```

Do not force past the refusal. The version this replaced warned and rebooted the
node anyway, which left `zitadel-db` stuck mid-switchover and `grafana-db` with
no active instance. Whether pod anti-affinity would let CNPG vacate a cordoned
node on its own — and remove this step — is an open question in `backlog.md`.

⚠️ **The first apply after a `talos_version` bump fails on OVH and Outscale**
with "Provider produced inconsistent final plan", once per machine config.
Nothing is left half-applied; re-run it. This is upstream
`siderolabs/terraform-provider-talos` #352, fixed only in the 0.12.0 pre-release
line — details and the decision still open in `backlog.md`.

## What to check, beyond "it came back"

After each node, and again at the end:

- **its name is unchanged** — a `talos-xxxxx` entry means the hostname did not
  hold, and the next reboot will orphan another node object
- the node count has not grown, and etcd still reports every member
- the probe's FAIL count has barely moved
- **`tofu plan` is empty.** If it wants to replace nodes, the boot image and the
  running version have disagreed — that plan would take the cluster down. Stop
  and read § Node image drift before running anything else.

```bash
task plan ROLE=management PROVIDER=<p> STRICT=1   # exit 2 = not converged
```

## Replacing a node rather than upgrading it

`--upgrade` cannot carry an `instance_type`, disk or zone change, nor a new image
schematic — those need a new VM. Same script, without `--upgrade`: it drains,
applies a targeted `-replace`, and waits, one node at a time. That path *does*
need the new cloud image to exist.
