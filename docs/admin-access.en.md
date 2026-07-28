# Day 1 — admin initialisation after `task up` (management)

🇫🇷 [Version française](admin-access.md)

**Ordered** walkthrough of the manual post-deployment steps. Each one points to
its brick's detailed runbook. Validated under real conditions (Scaleway,
2026-07-25). Convention: `KC=infrastructure/opentofu/cluster/kubeconfig`.

## 1. Escrow (IMMEDIATE — before anything else)

Three secrets to store in Bitwarden EU (then wipe from local output):

| What | Where to read it | Why |
|---|---|---|
| Shamir shares (5/3) + root token | `kubectl --kubeconfig $KC logs -n foundation-vault job/openbao-init` (also in Secret `openbao-recovery`, keys `root_token`/`unseal_key_*`) | OpenBao unseal/DR — the truth must live OFFLINE |
| restic backup password | `kubectl --kubeconfig $KC logs -n foundation-vault job/openbao-vault-bootstrap` (`BEGIN RESTIC PASSWORD` block, printed ONCE at generation) | without it the backups are undecryptable the day OpenBao is lost |
| State passphrase (`TF_VAR_encryption_passphrase`) | already in your vault (deploy prerequisite) | tfstate + gpg artifacts + etcd snapshots |

Runbooks: `OpenAether-apps/apps/base/foundation/vault/README.md` (rekey/DR),
`OpenAether-apps/apps/base/backup/README.md`.

## 2. Sign the PKI intermediate (unblocks HTTPS)

The bootstrap Job prints the CSR (`BEGIN INTERMEDIATE CSR` in its logs). Sign it
OFFLINE with the root CA (Bitwarden), then:

```bash
kubectl --kubeconfig $KC exec -i openbao-0 -n foundation-vault -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root_token> \
  bao write pki/intermediate/set-signed certificate=@- < intermediate-signed.pem
```

→ the `openaether-tls` Certificate goes Ready on its own (cert-manager retries),
and the gateway's 443 listener is programmed.
Detailed runbook:
`OpenAether-apps/apps/base/foundation/vault/pki-root-offline-runbook.md`.

## 3. Enable backups (backup brick, default companion)

The buckets must **pre-exist** (restic does not create them) — one per
destination, on different providers in production. Then seed the destinations in
OpenBao:

```bash
bao kv put secret/backup/s3-primary endpoint="https://s3.fr-par.scw.cloud" \
  bucket="s3-openaether-scaleway-backups-dev" access_key=… secret_key=…
bao kv put secret/backup/s3-replica endpoint="https://s3.eu-west-par.io.cloud.ovh.net" \
  bucket="s3-openaether-ovh-backups-dev" access_key=… secret_key=…
```

Until seeded: `ExternalSecret backup-restic-env` stays NotReady and the CronJobs
are idle (by design). Test with
`kubectl create job --from=cronjob/openbao-snapshot test -n foundation-vault`.
Details: `OpenAether-apps/apps/base/backup/README.md`.

**`secret/backup/s3-primary` feeds three mechanisms**: restic repositories, CNPG
PITR (`barmanObjectStore`) and Longhorn volume backups. One destination to seed
for all three.

**Loki has its OWN destination** — deliberately separate, so it never gets write
access to the backup bucket:

```bash
bao kv put secret/observability/loki-s3 \
  endpoint="https://s3.fr-par.scw.cloud" bucket="s3-openaether-scw-loki-dev" \
  accessKey=… secretKey=…
# Locally, to reproduce the previous behaviour (internal MinIO):
bao kv put secret/observability/loki-s3 \
  endpoint="http://minio.foundation-storage:9000" bucket="loki" \
  accessKey=… secretKey=…
```

⚠️ Until that path is seeded, **Loki does not install** (its HelmRelease consumes
the Secret through `valuesFrom`). That is intentional: a visible failure beats a
Loki silently writing to the wrong place.

## 3bis. Account quotas — check BEFORE deploying

Quotas read directly from the APIs on 2026-07-27:

| Provider | Instances | vCPU | RAM |
|---|---|---|---|
| **Outscale** | 10 | 20 | **40 GB** |
| **OVH** (project in use) | **10** | 34 | 420 GB |
| Scaleway | not constraining on this account | | |

What that means in practice:

- **Outscale**: an HA management (3 CP + 3 workers + bastion) needs **44 GB**
  against a 40 GB ceiling. The overrun is **tolerated at creation**, then any
  further VM is refused (`CreateVms → 10042 TooManyResources`). Nothing surfaces
  in the CAPI CR: the `OscMachine` loops in `VmNotReady` with an endlessly
  reallocated IP, and you have to read the CAPOSC manager logs to understand.
  → an HA Outscale management **and** an Outscale child are mutually exclusive
  on this account.
- **OVH**: 10 instances, i.e. the management (7 with the bastion) plus **one**
  child (2). No room for a second one.

Preflight, before any `task up` or child activation:

```bash
source .env.sh
task preflight-quotas PROVIDER=outscale -- --add-vms 7 --add-cores 14 --add-ram-gb 44
```

It exits non-zero if the requested topology overflows — exactly the scenario
that cost two deployments.

## 3ter. Schedule the etcd snapshot (operator)

The etcd snapshot is an **RTO shortcut**: cluster content is rebuilt by Flux, but
a few objects live ONLY in etcd (Secrets written by Jobs, PVC bindings…).
`task etcd-snapshot` does it on demand; nothing triggered it periodically.

```bash
# 03:40 daily — an ABSOLUTE path is mandatory; output is mailed by cron
40 3 * * * /path/to/OpenAether-infra/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/id_ed25519-ovh-openaether-dev >> /var/log/openaether-etcd-snapshot.log 2>&1
```

The wrapper exists because the task alone is not cron-usable:

- cron starts with a minimal `PATH`, and the tools are scattered (`task` and
  `talosctl` in `/usr/local/bin`, `tofu` and `aws` in `/snap/bin`);
- credentials come from `.env.sh`, which cron does not inherit;
- **`task etcd-snapshot` opens SSH tunnels and never closes them** — under cron
  they would pile up; the wrapper closes them even on failure;
- a `flock` prevents a slow snapshot from overlapping the next one.

It runs on the machine that holds both the repository and the credentials. A
failure exits non-zero with a timestamped message — enough for cron or a
supervisor to notice.

## 4. Admin access to the UIs (restricted interface)

Exposure: the gateway sits on a **private VPC IP** (LB-IPAM pool) with the
bastion SG restricted to `admin_ip` → nothing public. Routes:
`vault|grafana|zitadel|longhorn.openaether.local`.

- **Without TLS (troubleshooting)**: `./scripts/ops/local-admin-portforward.sh`
  (loopback-only port-forwards).
- **HTTPS (after step 2)**:
  ```bash
  ssh -i <bastion key> -L 8443:<gateway IP>:443 bastion@<bastion IP> -N
  # gateway IP: kubectl get gateway -n services-gateway ; bastion: tofu output bastion_ip
  # /etc/hosts: 127.0.0.1 grafana.openaether.local vault.openaether.local zitadel.openaether.local longhorn.openaether.local
  ```
  → `https://grafana.openaether.local:8443`; import the root CA into the browser
  for a clean chain. (Alternative without remapping:
  `sshuttle -r bastion@<IP> 172.16.12.0/22`.)
- Credentials: Grafana → `bao kv get secret/grafana/admin`; Zitadel → init
  console.
- **OpenBao — do NOT use the root token day to day.** It never expires, cannot
  be usefully revoked, and appears in no audit trail under a human's name. Two
  named policies are created at bootstrap:

  ```bash
  # human access, 8 h, traced under a name
  bao token create -policy=openaether-admin  -ttl=8h -display-name=firstname
  bao token create -policy=openaether-reader -ttl=8h -display-name=firstname   # read-only
  ```

  `openaether-admin` covers day-to-day operations (secrets, PKI, policies, auth,
  mounts, leases) but **explicitly denies** seal, `step-down`, rekey and key
  rotation. Those last-resort actions stay with the offline-escrowed root token:
  deliberate, never routine.
- ⚠️ If your public IP changes: update `admin_ip` in the tfvars then run
  `task infra` (otherwise the bastion is unreachable — tunnels 0/N).

## 4bis. Grafana SSO via Zitadel (OIDC)

Grafana now accepts Zitadel authentication **in addition to** its local admin.
The local form stays enabled on purpose: it is the safety net if SSO breaks or
is not configured yet. Only disable it (`disable_login_form`) once SSO is
proven.

✅ **Already done on the OVH cluster of 2026-07-28** (project `OpenAether`, role
`grafana-admin`, web application `Grafana`, `secret/grafana/oidc` seeded). The
steps below apply to a NEW cluster.

⚠️ **The roles scope is mandatory**: without
`urn:zitadel:iam:org:projects:roles` in `scopes`, Zitadel emits no role claim at
all and every account stays `Viewer`. Measured for real. It is now set in
`apps/base/observability/grafana.yaml`.

To do once on the Zitadel side (console or API):

1. Project "OpenAether" → **Application** of type **Web**
2. Authentication method **Code** (PKCE) + client secret
3. Redirect URI: `https://grafana.openaether.local/login/generic_oauth`
   Post-logout: `https://grafana.openaether.local/login`
4. To drive roles: create a project role `grafana-admin`, assign it, and enable
   "User Info inside ID Token"
5. Store the credentials:

```bash
bao kv put secret/grafana/oidc client-id=… client-secret=…
```

Until that path is seeded, **Grafana still starts** (the OIDC environment
variables are `optional`): only the Zitadel button is inert. This is deliberate
— an unconfigured SSO must not lock you out of Grafana.

⚠️ To verify on the first deployment: the **structure** of the roles claim. The
name (`urn:zitadel:iam:org:project:roles`) is confirmed by Zitadel's docs, but
its exact shape depends on the application configuration:

```bash
curl -H "Authorization: Bearer <token>" https://zitadel.openaether.local/oidc/v1/userinfo
```

Adjust `role_attribute_path` in `apps/base/observability/grafana.yaml` if needed.
`role_attribute_strict: false` falls back to `Viewer` on a mismatch rather than
denying access.

The Grafana → Zitadel network path (`:8080`, code exchange then
`/oidc/v1/userinfo`) is open on both sides in the CiliumNetworkPolicies —
without that, login would fail with "operation not permitted", leaving nothing
but a timeout on the Grafana side.

## 4ter. BROWSER tests — what cannot be validated any other way

Everything else in the foundation can be checked from the command line. These
three cannot: they rely on redirects and cookies.

### BLOCKING prerequisite — sign the PKI intermediate

Nothing is reachable through the gateway until step 2 is done: the HTTPS
listener stays `Programmed=False` and the `openaether-tls` certificate fails
with

```
Vault failed to sign certificate: no default issuer currently configured
```

That is expected: OpenBao's PKI has no signed intermediate. Check with:

```bash
kubectl get gateway -n services-gateway openaether-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

Both must read `True`. Otherwise, go back to step 2.

### Open the access

```bash
ssh -i <bastion key> -L 8443:172.16.12.241:443 bastion@<bastion IP> -N
# /etc/hosts:
# 127.0.0.1 grafana.openaether.local zitadel.openaether.local vault.openaether.local longhorn.openaether.local
```

Import the **root CA** into the browser, otherwise every page raises a
certificate warning that will mask the real symptoms.

### Test 1 — Grafana SSO (the only genuinely open point)

The Zitadel application, the `grafana-admin` role and the secret are already in
place. On `https://grafana.openaether.local:8443`:

1. the **"Sign in with Zitadel"** button is present → the config is loaded;
2. it redirects to Zitadel and login succeeds → `client_id`/`client_secret` and
   the redirect URI are correct;
3. **the point to settle**: the resulting role. Menu *Administration → Users*.
   - an account holding `grafana-admin` shows as **Admin** → the mapping works,
     nothing more to do;
   - everyone shows as **Viewer** → the roles claim is not the expected one.
     Zitadel emits two name forms depending on context; we picked the
     unprefixed one. To settle it, decode the token:

     ```bash
     # from the Grafana page, grab the access token (dev tools → network)
     curl -H "Authorization: Bearer <token>" \
       https://zitadel.openaether.local:8443/oidc/v1/userinfo | jq 'keys'
     ```

     If the key is `urn:zitadel:iam:org:project:<ID>:roles`, put that ID into
     `role_attribute_path` (`apps/base/observability/grafana.yaml`). The
     STRUCTURE itself is confirmed: an object whose keys are the roles, so
     `keys()` remains correct.

⚠️ The local login form stays enabled: it is the safety net if SSO fails. Only
disable it (`disable_login_form`) once this test passes.

### Test 2 — the OpenBao UI behind the gateway

`https://vault.openaether.local:8443` must show the unseal/login screen. This is
what validates the `DestinationRule` using `credentialName`: the gateway now
speaks **verified** TLS to OpenBao. A blank page or a 503 with an OpenBao log
saying `TLS handshake error … client sent an HTTP request to an HTTPS server`
would mean the DestinationRule is not being applied.

### Test 3 — PUBLIC ingress (outside the tunnel)

Both tests above go through the private VIP. To validate the public path
end-to-end, target the application LB IP **without a tunnel**:

```bash
curl -kv --resolve grafana.openaether.local:443:<app LB IP> \
  https://grafana.openaether.local/login
```

The LB → nodePorts 30080/30443 wiring is already verified on the infrastructure
side; this test confirms the full application traversal.

## 5. CAPI child clusters (if the layer is picked)

Before enabling a file in `apps/clusters/` (see its README), place the secrets
**outside git**:

```bash
kubectl --kubeconfig $KC create secret generic scaleway-capi-credentials -n capi-clusters \
  --from-literal=SCW_ACCESS_KEY=… --from-literal=SCW_SECRET_KEY=…
kubectl --kubeconfig $KC create secret generic <child>-substitutes -n flux-system \
  --from-literal=SCW_PROJECT_ID=…
```

Child kubeconfig (generated by CAPI):

```bash
kubectl --kubeconfig $KC get secret <child>-kubeconfig -n capi-clusters \
  -o jsonpath='{.data.value}' | base64 -d > <child>.kubeconfig && chmod 600 <child>.kubeconfig
```

⚠️ **Never change the Cilium `values` of a live child.** The Helm upgrade rolls
the CNI on a cluster that often has only 2 nodes and no headroom: on 2026-07-26
both edges came out degraded (one with its inter-node datapath permanently
broken, `cilium-dbg status` → `Cluster health 0/2 reachable`). **Recreating the
child** (`task edge-down` then re-enable its file) is faster and safer than
repairing it. The correct values — including `cni.exclusive: false`, mandatory
as soon as Istio ambient is picked, and `ipam.mode: kubernetes`, without which
pod CIDRs are carved out of `10.0.0.0/8` where the node subnets live — are
already in `apps/clusters/*.yaml`: a child created today gets them at bootstrap.
`task apps-validate` checks that alignment before any deployment.

Expected for a healthy child on the `workload` profile: **19/19 Kustomizations**
(18 from the profile + the root laid down by the scaffold). This count **moves
every time a brick is added to the DAG** — it was 17/17 before 2026-07-27, then
18/18. Do not read it as a regression: check it with
`python3 scripts/pick.py vault eso certs gateway` (apps side), which reports how
many Kustomizations are retained.

Check a child's state:

```bash
kubectl --kubeconfig <child>.kubeconfig get kustomization -n flux-system
# if `kubectl logs/exec` times out while the nodes are Ready:
#   apiserver → kubelet:10250 is blocked (security group) — see docs/backlog.md
```

## Recap checklist

- [ ] Shamir shares + root token escrowed (Bitwarden)
- [ ] restic password escrowed (Bitwarden)
- [ ] Intermediate signed + `set-signed` (HTTPS working)
- [ ] Backup buckets created + `secret/backup/s3-{primary,replica}` seeded
- [ ] First snapshot tested (manual job → both destinations)
- [ ] Root CA imported into the browser, tunnel tested
- [ ] (CAPI) child secrets placed, kubeconfig extracted
