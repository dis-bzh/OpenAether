> 🇫🇷 [Version française](first-cluster.fr.md)

# Your first cluster

From a bare machine and an empty cloud account to a Talos cluster you can reach,
upgrade and destroy. Scaleway is used throughout; OVH and Outscale differ only in
their credentials and their tfvars file.

**Read the honesty note at the bottom before you spend anything.** Parts of this
path have never been walked end to end, and this document says which.

## What you get, and what you do not

A single Talos Linux cluster: 3 control planes, 2 workers, Cilium as the CNI, an
apiserver load balancer ACL'd to your IP, a bastion, and an OpenTofu state
encrypted on your side before it reaches S3.

No applications, no GitOps, no ingress. Flux exists in the code and is **off**
(`deploy_flux = false`); it returns as a choice in a later release. Cilium does
not need it — Talos delivers Cilium itself, as an inline manifest, before
anything else runs.

## Before you start

- A Scaleway account, and the quota to run **5 instances** of the type in your
  tfvars. A new account may be capped at 1 — Console → Quotas. There is no
  preflight script for Scaleway (`preflight-quotas.py` covers OVH and Outscale
  only), so this check is yours to make.
- An SSH keypair you already have, or `ssh-keygen -t ed25519`.
- Somewhere to keep a passphrase you cannot afford to lose: it encrypts the
  state, the kubeconfig and the talosconfig, and nothing can decrypt them
  without it.

## 1. The machine

```bash
git clone https://github.com/dis-bzh/OpenAether-infra && cd OpenAether-infra
./scripts/setup.sh
```

Installs OpenTofu, talosctl, kubectl, Task, the AWS CLI, gpg and the rest.
Needs root or sudo. Ends on `🚀 Environment ready!`.

Do **not** start with `task setup` — `task` is one of the things this script
installs.

## 2. Credentials

```bash
cp .env.example .env.sh
$EDITOR .env.sh
source .env.sh
```

Fill in, for Scaleway: `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`,
`SCW_DEFAULT_PROJECT_ID`, `SCW_DEFAULT_ORGANIZATION_ID`, the region and zone,
and `SCW_AWS_ACCESS_KEY_ID` / `SCW_AWS_SECRET_ACCESS_KEY` for S3.

And the one that matters most:

```bash
TF_VAR_encryption_passphrase="$(openssl rand -base64 48)"
```

Minimum 32 characters, and **the placeholder shipped in `.env.example` is long
enough to pass that check** — nothing will stop you deploying with it. Replace
it. Losing this passphrase means losing the state and both access artifacts.

Do not export `AWS_*` yourself: the flow derives them per provider from the
namespaced variables above.

Nothing verifies this file. The first command that complains about a missing
credential runs after `task up` has already created a bucket.

## 3. The cluster file

```bash
cd infrastructure/opentofu/cluster/envs
cp management-scaleway.tfvars.example management-scaleway.tfvars
$EDITOR management-scaleway.tfvars
```

| field | what to put in it |
|---|---|
| `cluster_name` | yours. **It has a default, so no checker will tell you to change it** — and its first segment names all four cluster buckets |
| `bucket_suffix` | **set it unless you are the original author.** S3 bucket names are unique across a whole provider, not per account — Scaleway documents them unique "in our whole platform", OVH "within OVHcloud". Without one you will collide with names somebody already took. `task bucket-suffix` prints one; pick it once, changing it later orphans every bucket you have |
| `environment` | `dev` or `prod`, nothing else. `prod` additionally requires the replica store to be on a different provider |
| `admin_ip` | `curl -s ifconfig.me` as a `/32`. It is both the SSH allow-list and the apiserver LB ACL |
| `s3_primary_endpoint` / `_region` | S3 on the same provider as the cluster |
| `s3_replica_endpoint` / `_region` | S3 for the backup copy. In production, **a different provider** — a state you can only read from the cloud that just failed is not a backup |
| `bastion_ssh_keys` | the **public** half of the key you will pass as `KEY=`. `task up` refuses to start if they do not match, before spending anything |
| `control_planes` | 3. Nothing validates this; `2` silently builds a two-member etcd |

`git_repo_url`, `git_ref`, `flux_namespace` and `apps_profile` are inert while
Flux is off. Leave them.

## 4. Bring it up

```bash
cd ../../../..
task up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey
```

Needs a terminal: the apply asks for approval twice, and it applies the plan it
just showed you — do not reach for `-auto-approve`, which applies a *different*
plan computed at that moment. (For an unattended run, save one first:
`task plan … OUT=tfplan`, read it, then `task apply-plan PLAN=tfplan`.)

In order it builds the Talos image and uploads it — **measured at 52 s on
Scaleway, 2026-08-17**, for two buckets, one snapshot and one image per zone —
creates four more buckets, applies the infrastructure, opens one SSH tunnel per
node, then applies the machine configs and bootstraps Talos.

Six buckets exist afterwards: state and artifacts, each with a `-backup` twin,
plus the image and its staging area.

Re-running resumes — **except when your edit adds a node**, which is a known
open defect (`docs/backlog.md`), not something you did wrong.

## 5. Talk to it

```bash
export KUBECONFIG=$PWD/infrastructure/opentofu/cluster/kubeconfig
kubectl get nodes
```

The file is already there, written by the bootstrap. If it is not, or you are in
a fresh shell: `task kubeconfig PROVIDER=scaleway`.

The apiserver is the public load balancer, ACL'd to your `admin_ip`, so plain
`kubectl` works with no tunnel.

For Talos itself, every command needs an explicit node — the talosconfig carries
endpoints but no default node:

```bash
cd infrastructure/opentofu/cluster
talosctl --talosconfig talosconfig -n "$(tofu output -json control_plane_private_ips | jq -r '.[0]')" etcd members
```

Those endpoints are **local tunnels**. `task close-tunnels` makes the talosconfig
unusable until you reopen them.

## 6. Ask the cluster whether it worked

```bash
task verify PROVIDER=scaleway
```

Asks the cluster, not the tool: the apiserver answers, every node is Ready, the
number of control planes matches what you asked for, Cilium runs on each of
them, CoreDNS serves, there is no `flux-system`, no application load balancer,
and a state replica exists in the backup store.

Every check can fail. A verification that warns and ends green is the defect
this file exists to avoid.

## 7. Upgrade

`docs/upgrade.md` is the procedure — Kubernetes first, then Talos, one node at a
time, in place. Start the probe before you begin: the claim this project makes
is not "no interruption", it is **the longest run of consecutive failed
`/readyz` samples, one second apart, stays under 15 seconds**. Measure it.

## 8. Tear it down

```bash
task destroy ROLE=management PROVIDER=scaleway
task fleet-down PROVIDER=scaleway -- --force-no-edges --yes
python3 scripts/ops/purge-orphans/scaleway.py
```

`--force-no-edges` is required and the bare `--` is not optional. `fleet-down`
refuses to destroy a cluster until it has ruled out CAPI children; a
pure-infrastructure cluster has no CAPI CRDs, so that query can never succeed and
the flag is how you say there are none.

The buckets and the Talos image survive on purpose — deleting the state bucket
also deletes any possibility of restoring. `fleet-down` lists them by name.

Nothing should be billing afterwards. The purge script asks the provider rather
than the state file; that is the only answer that counts.

## 9. If you lose access

The kubeconfig and the talosconfig are encrypted on your machine and copied to
both stores every time the cluster changes. To get them back:

```bash
task restore-artifacts PROVIDER=scaleway                 # from the primary store
task restore-artifacts PROVIDER=scaleway FROM=replica    # when that provider is the problem
```

`FROM=replica` reads the second store with its own credentials — in production a
different provider, which is the whole point: a copy you can only read from the
cloud that just failed is not a backup.

It will not overwrite a file that is already there unless you pass `FORCE=1`;
without it, the recovered copy lands beside the existing one as
`kubeconfig.restored`.

Nothing recovers these without `TF_VAR_encryption_passphrase`. There is no
second key and no reset.

## What is not proven

Honest as of 0.5.0, and the reason this document exists:

- **This path has never been walked end to end from a clean machine.** It was
  assembled by reading the code, not by following it.
- `task verify` has never run against a cloud cluster. Its checks pass on a live
  local Docker cluster (6/6, 2026-08-17), and the cloud-only branches — the
  control-plane count against the state, the app load balancer, the state
  replica — have never executed anywhere.
- Nothing has ever opened a stored *state* object to confirm it is ciphertext.
  The encryption is declared and implemented; it is not verified on S3.
- The restore ROUND TRIP is proven offline: the real encryption function against
  the real decryption function, byte for byte, wrong passphrase refused
  (`scripts/dev/test-restore.sh`). What is **not** proven is the transport —
  that the object is really in the bucket and comes back from it. That is one of
  the things the first paid run is for.
- The Talos upgrade is proven on Scaleway. On OVH some nodes have come back on
  the previous version, and that is open.
- Every bucket name derives from `cluster_name` except the Talos image ones,
  which are hardcoded. In another account they may collide.

Found something this document gets wrong? That is the most useful bug report
this project can receive.
