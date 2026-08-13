# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.1.0] — 2026-08-12

Written in English: this file is documentation, and the repository's rule is that
English is canonical. The 1.0.0 entry below stays in French, unrewritten.

**Numbered 1.1.0, not the 1.0.1 this section was drafted as.** The emulated lane
is a new capability, not a patch, and 1.0.1 was never tagged. 1.0.0 is untouched:
this project pins deployments by tag, so moving one would silently change what a
cluster reconciles.

### Added

- **An emulated cloud lane — real provider binaries, no account, no bill.**
  [Feint](https://github.com/stephrobert/feint) serves the Scaleway and Outscale
  APIs on loopback; `task feint-plan` runs the real `cluster` root against it and
  `task feint-apply` a full create / empty re-plan / destroy confirmed by the API,
  not by the state. It sits between `tofu test`, where the provider is mocked and
  never leaves the process, and a real deployment. Two locks, because the failure
  mode is spending money by accident: the endpoint variable rejects anything that
  is not loopback, and the lane pins fake credentials so a provider cannot fall
  back to your profile. What it proves and what it does not is in
  `docs/emulated-cloud.md` — Feint has no inventory, so a nonexistent image or
  machine type is accepted where a real cloud refuses.
- **`task feint-record`** ranks what our modules call that the emulator does not
  serve, so the gap is measured instead of guessed. Four operations remain.
- **A credentialed staging workflow** (`workflow_dispatch` + weekly), deploying,
  verifying and destroying on a real provider, with a reaper that runs even when
  the deploy job never reached its teardown. Never `pull_request`: this
  repository is public and that trigger would hand a stranger its cloud
  credentials.

### Changed

- **`rolling-replace.sh` can now upgrade in place (`--upgrade`).** Replacing a VM
  to change its Talos version throws away everything that made the node itself:
  its disk, its identity, its etcd membership. `talosctl upgrade` keeps all three,
  cordons and drains on its own, and refuses a control-plane upgrade that would
  cost etcd its quorum. The script's own gates still run, still one node at a
  time, and a node already on the target version is skipped rather than rebooted.
  Replacement stays the default for anything that is not a version change.
- **Relicensed from AGPLv3 to Apache 2.0.** The copyleft was deterring the one
  thing this project wants — people running it. Apache 2.0 matches Feint, which
  OpenAether now depends on for its emulated lane. A relaxation, so anything
  already obtained under AGPLv3 remains available under it.
- **Talos v1.13.8**, and the vendored artifacts match their generators again.
  Renovate raised Cilium to 1.20.0 and Flux to v2.9.3 on 2026-07-30 and moved
  only the pinned versions, never the rendered files: for two weeks, and through
  the 1.0.0 tag, clusters bootstrapped a Cilium missing the whole 1.20 config
  surface and a Flux built by an older controller-gen. `task render-check`
  existed and caught it — nothing ran it. It is a CI job now.
- **The OpenAether-apps ref is a variable, and defaults to a tag.** `git_branch` was
  hardcoded to `"main"`, so no version of this repository identified a deployable
  system: a commit in the platform repo could change a running cluster within the
  reconcile interval. `git_ref` takes a fully-qualified ref, defaults to
  `refs/tags/1.1.0`, and every `envs/*.tfvars.example` pins it. Branch tracking stays
  available (`refs/heads/<branch>`), which is also how two managements avoid sharing
  `apps/clusters`.
  The Flux `GitRepository` now uses `ref.name` rather than `ref.branch` — one field that
  carries either — and the substitution injected through the gitception loop is
  `GIT_REF` instead of `GIT_BRANCH`. **The examples require OpenAether-apps 1.1.0**, so that
  tag is cut first; nothing else depends on it existing.
  Rung: proven on live clusters, 2026-08-12. `OpenAether-apps` had never carried a
  tag at all, so the examples pointed at a ref that could not resolve and every real
  deployment had silently fallen back to a branch. Tagged, pinned, and checked on
  Scaleway, OVH and Outscale: the `GitRepository` reports Ready against
  `refs/tags/…@sha1:…`.
- `apps/clusters` no longer enables the DIS fleet's own children by default; see the
  OpenAether-apps 1.1.0 entry.

### Fixed

Most of what follows was found on 2026-08-12 by running the release checklist on
a real machine and three real clouds rather than trusting CI. They share a shape
worth naming: **a check that could not fail**, or one asserting something other
than what its name promised. None of them was visible from a green pipeline.

- **A backup of a tfvars was not ignored.** `*.tfvars` does not match
  `management-ovh.tfvars.bak`, so copying an env file before editing it — which
  is what anyone does — left real IPs, image ids and account data untracked but
  visible in a public repository. Found by doing exactly that while validating
  this release. `*.tfvars.*` now covers the derived forms.
- **The k8s listener on OVH diffed against its own state on every plan.**
  Octavia returns `allowed_cidrs` sorted, the provider treats the attribute as
  ordered, and the config sent it unsorted: OVH was never idempotent. The values
  were always identical; only the order was not.
- **A worker could never be upgraded in place, and no node could be drained.**
  `talosctl upgrade` fetches a kubeconfig from the endpoint it is talking to in
  order to drain, and a worker does not serve one — the install completed, the
  command failed, the node never rebooted into the new version. Behind that, a
  second wall: seven PodDisruptionBudgets allow zero disruptions, so the drain
  could not finish either. The endpoint is always a control plane now, and the
  drain is ours — the one that reports a stuck eviction and lets the operator
  decide — with `talosctl --drain=false`. The budgets belong to OpenAether-apps
  and are in the backlog. Both faults were invisible from Scaleway, which had
  only ever rolled control planes.
- **`task test` deleted the operator's cluster credentials.** The suite mocks
  every cloud provider but not `local`, so `local_file.kubeconfig` and
  `local_file.talosconfig` were genuinely written into the module directory —
  mock content over a live cluster's files — and genuinely removed when the run
  tore down. It cost access to a cluster mid-upgrade while validating this
  release. `local` is mocked too now, and the files come through a run
  byte-identical.
- **A reboot could rename a node, and a Talos upgrade did.** Our images are
  `metal` builds, so Talos has no cloud metadata to take a name from: the names
  came from DHCP, and the generated config falls back to `auto: stable` when a
  lease arrives without one. `talosctl upgrade` on a control plane brought it back
  as `talos-8g3-a2w` — a second Kubernetes node object, the old one left NotReady,
  and the etcd member renamed with it. The orphan is not cosmetic:
  `data.talos_cluster_health` cannot pass while a node is NotReady, so `tofu plan`
  itself wedges. Both roles now carry a `HostnameConfig` document with a static
  name, which outranks DHCP and holds across reboots on every provider.
- **After an in-place upgrade, the next `tofu apply` would have destroyed the
  cluster.** `talosctl upgrade` changes the running version without touching the
  cloud resource, so bumping `talos_version` leaves the instance's image id stale
  — and that attribute is ForceNew on Scaleway, a disk-wiping rebuild on
  OpenStack. Planned against a freshly upgraded cluster, it proposed replacing all
  three control planes at once: six destroys, and etcd quorum with them. Node
  resources now ignore that attribute, since the boot image is the install medium
  and not the running version; the same plan then showed zero destroys. Deliberate
  re-imaging is unchanged — `rolling-replace` passes an explicit `-replace`, one
  node at a time.
- **`./scripts/setup.sh` installed nothing at all on a clean machine.** Three
  prerequisites hidden behind one another, each turned into a total abort by
  `set -euo pipefail`: OpenTofu's installer refuses without `unzip` and without
  either `cosign` or `gpg`, then `sudo` does not exist in a container already
  running as root. In a bare `ubuntu:24.04` it exited 1 having installed nothing;
  it now installs the seven tools and reports a missing `nc` without pretending
  otherwise.
- **`task validate`, `task test` and `task security` were only ever green on a
  fresh CI runner.** `validate` broke on a stale provider lock the moment a
  version constraint moved; `test` claimed in its own comment to match it but had
  copied only the flag, not the data-dir isolation, and needed a credential file
  the mocked lane exists to avoid; `security` scanned `.env.sh` and the
  `*.kubeconfig` files, gitignored by design, so it could not be green where it
  is meant to run. Watch out for `gitleaks dir`: it takes one path and silently
  scans everything if handed a list.
- **`test-talos-local.sh` reached its green banner on a cluster with no CNI.**
  Its header said the degrade-to-warning bug was fixed; it was, for etcd only.
  Node-readiness and Cilium were still warnings. Proven by deleting the Cilium
  DaemonSet: the old checks printed yellow and exited 0.
- **The staging workflow could never have deployed anything.** It sets
  `TF_INPUT=0` and has no tty, and `task infra` applies without `-auto-approve`
  on purpose — so its first apply aborted, every time, after loading the secrets.
- **`rolling-replace` replaced nothing on OpenStack.** `-target` narrows a plan,
  it forces nothing, and an image change is only ForceNew on Scaleway: a Talos
  bump rewrote the attribute in place and left the VM on the old image, the state
  claiming a version no node was running. It also invented node names from a
  convention Outscale does not follow, where every `kubectl cordon` would have
  failed. Both fixed; names now come from the cluster, by private IP.
- **`talos-image` printed the right image id and let you deploy the wrong one.**
  On OVH and Outscale the cluster reads the id from a tfvars, copied by hand, and
  nothing compared the two — a rebuilt image failed at server creation, after the
  network and bastion were billed. It refuses now.
- **`talos_machine_bootstrap` retried an unreachable node for 2h46 on billed
  resources**, having no timeout while the two resources above it do. Bounded to
  15m. Its comment also called it idempotent, which it is not.
- **A unit test named `installer_image_uses_talos_version` asserted that the
  variable it had just set held the value it set.** The installer reference it
  claimed to cover is what decides the Talos version a node actually runs.
- **Two of the three `purge-orphans` scripts never said "clean".** They printed
  only their dry-run footer, so an empty account and a full one differed by the
  absence of lines. These are the last thing between a failed teardown and a bill.
- **`task local-up` built a cluster with no CNI on a fresh clone.** `cilium-local.yaml`
  is gitignored, `local-up` had no render step, and the fallback emitted the string
  `placeholder` — which the precondition in `modules/talos` does not match, because it
  looks for `CILIUM-MANIFEST-PLACEHOLDER`. Three call sites checked that sentinel and
  none ever wrote it, so the guard could not fire and an 11-byte inlineManifest shipped
  as the CNI. It only failed for someone who had never rendered, i.e. every new reader.
  `local-up` now renders when the file is missing, and the fallback emits the sentinel
  the guard actually looks for.
- **Every local verification dialled a port that is never published.** `local-status`
  and `scripts/dev/test-talos-local.sh` hardcoded `127.0.0.1:50000`, the container-side
  port, while the host base is `talos_api_port_base` (45000). Both now derive from that
  base. The two checks that hid the defect above — etcd quorum and Talos health — fail
  the run instead of warning and ending on a green banner.
- **`scripts/setup.sh` did not install `helm`**, which `README` claimed it did and which
  `render-bootstrap-manifests.sh` needs. It installs it now, and reports a missing `nc`,
  required by the local provider and the SSH tunnels.
- **Six `envs/*.tfvars.example` could not be planned as written**: `bastion_ssh_keys`
  held a bare string against a `map(list(string))` variable.
- Both READMEs announced `v0.4.0+` and pointed at an empty `[Unreleased]`, at the 1.0.0
  tag itself; and the WSL2 note gave a port default of 41000 against an actual 45000.

## [1.0.0] — 2026-07-31

**Premier socle stable : multi-provider, multi-cluster, automatisé, idempotent.**
Fleet réelle 3 providers (management + edges) déployée, opérée (upgrade rolling
zéro coupure), et détruite proprement de bout en bout ; alerting, backup/DR et CI
validés en réel. Point de bascule : les deux derniers comportements non-idempotents
connus (`task up` re-run, nettoyage provider du teardown) sont corrigés et
re-vérifiés en réel avant ce tag — voir « Fixed » ci-dessous.

**Recentrage produit — socle Talos modulaire, management CAPI optionnel.** OpenAether
déploie **un cluster Talos sur n'importe quel provider** (Proxmox ou cloud) avec pour
**seul socle figé CNI (Cilium) + Flux**, puis **pioche modulairement** dans les
manifests communs d'`OpenAether-apps` selon les dépendances voulues. Le
**multi-cluster (CAPI) reste un objectif mais devient une surcouche optionnelle**,
plus le point d'entrée (ni le plus simple ni le plus cheap) — un cluster ne devient
« management » qu'une fois CAPI + dépendances installés. Ce recentrage **élargit**
l'usage : du single-cluster autonome au hub multi-cluster. Backup + DR auto + sécu by
design + souveraineté restent la proposition de valeur. En cours : **ajout du provider
Proxmox** (SYS-1) aux côtés de Scaleway/OVH/Outscale ; abandon du multi-cloud
**actif-actif** (le hub/spoke reste possible, mais n'est plus la cible par défaut).

### Fixed — bootstrap cloud non-déterministe (garde-fou port-ready restauré)

- **`modules/talos` : réintroduction de `terraform_data.talos_port_ready_{cp,worker}`
  + `scripts/wait-talos-port.sh`.** Le bootstrap cloud pouvait **hang** sur
  `talos_machine_bootstrap`/`config_apply` (timeout 15m brûlé sur un nœud encore en
  boot). Cause : `0a7eb52` avait **supprimé** ce garde-fou TCP (`:50000` ready) en
  pariant sur le fix x509/Ed25519 du provider talos **0.12.0-alpha.2** ; `dab57cb` a
  ensuite **reverté le pin à `0.11.0`** (la 0.12.x n'a que des pré-releases) **sans
  remettre le garde-fou** → l'horloge de retry TLS du provider démarrait avant que
  l'API Talos du nœud cloud ne réponde. Invisible en local (`config_delivery=userdata`
  → ressources `config_apply` skippées). Restauré : le `config_apply` attend désormais
  `:50000` ouvert → bootstrap cloud **déterministe**. Inerte en local (`do_apply=false`).

### Added — snapshot etcd chiffré multi-destinations

- **`task etcd-snapshot PROVIDER=…`** + `scripts/ops/etcd-snapshot.sh` : snapshot etcd
  via `talosctl` (premier CP sain, tunnels 50000+i), chiffré **côté client** (gpg
  AES-256, S2K durci, même passphrase que le tfstate) puis poussé vers les buckets
  artifacts **primary + replica** (`backup_targets`), rétention `KEEP=30`. GitOps rend
  etcd reconstructible — c'est une bretelle RTO, complémentaire des backups in-cluster
  d'`OpenAether-apps` (brique `backup` : snapshot raft OpenBao + dumps CNPG via restic).

### Changed — rolling-replace généralisé aux 4 providers

- **`scripts/ops/rolling-replace.sh`** ne hard-code plus les adresses `module.scw` :
  les cibles sont dérivées de `tofu state list` (`module.<mod>[0].*.<type>[i]`), en
  **excluant les volumes de données** (qui survivent au remplacement) mais en incluant
  les ressources attach/link (recréées sur la VM neuve). Accepte
  `scaleway|ovh|outscale|proxmox` ; seul Scaleway a été exercé live — les autres
  affichent un avertissement (dry-run d'abord). Proxmox : disques workers inline →
  wipe + rebuild Longhorn depuis les répliques (avertissement dédié).

### Added — remplacement rolling des nœuds (sans coupure)

- **`task rolling-replace PROVIDER=…`** + `scripts/ops/rolling-replace.sh` : remplace
  les nœuds **un par un** lors d'un changement ForceNew (`instance_type`, image Talos).
  `task infra-management` recréait les 6 VM **en parallèle** → les 3 control-planes
  rebootaient ensemble → perte de quorum etcd → coupure. Le script draine puis
  recrée chaque nœud isolément (`tofu apply -target` instance + NIC, `-replace` du
  `talos_machine_configuration_apply` pour reconfigurer la VM fraîche), et attend la
  reconvergence Talos / etcd 3-3 / Longhorn entre chaque. Workers d'abord, puis CP
  (strictement 1 CP à la fois, gated sur le retour du quorum). Garde-fous : pré-check
  santé, arrêt au premier échec, `--dry-run`, `--workers-only` / `--cp-only`.
  Les data disks Longhorn (block volumes séparés) sont préservés ; seul le disque
  système est recréé. Avertissement ForceNew ajouté dans `modules/providers/scw/main.tf`.

### Changed — Identité : Keycloak → Zitadel

- **Zitadel remplace Keycloak** (décision actée). Zitadel (Go, multi-tenant
  natif) est plus léger et mieux adapté à la mutualisation clients que Keycloak
  (JVM). Repo `OpenAether-apps` :
  - Nouveau `apps/base/identity/zitadel/` — HelmRelease `zitadel` 10.0.2
    (appVersion v4.14.0), namespace `services-identity` (ambient), HTTPRoute via
    `openaether-gateway`, CiliumNetworkPolicy L4 (egress CNPG/DNS/kube-api),
    AuthorizationPolicy Istio (default-deny + allow gateway), ExternalSecrets
    (masterkey 32 o + password DB) depuis OpenBao.
  - CNPG `keycloak-db` → **`zitadel-db`** (DB/owner `zitadel`), ESO
    `keycloak-db-app` → `zitadel-db-app` (`secret/zitadel/db`).
  - Seeder OpenBao (`bootstrap-roles-job`) : seed `zitadel/db` + `zitadel/masterkey`
    (remplace `keycloak/db`), policy `secret/data/zitadel/*`.
  - Flux DAG : `apps/flux/base/35-identity.yaml` (Kustomization `identity`,
    dependsOn cnpg/external-secrets/istio/services-gateway). Suspendu en local
    (cloud-only : dépend de la Gateway TLS).

### Fixed — drift fondation (root OpenBao supprimé)

- Namespace mort `foundation-pki-root` retiré de `apps/base/namespaces/`
  (le root OpenBao n'existe plus depuis la refonte seal Shamir + unsealer HA).
- Règle egress cert-manager → ancien `foundation-pki-root` supprimée
  (cert-manager signe via l'unique OpenBao `pki/sign/openaether`).
- Commentaire DAG de l'overlay `management` mis à jour (plus de « 10 pki-root »).

### Added — multi-cluster CAPI réel, 3 providers

- **Management CAPI (`cluster-api-operator` + providers Scaleway/OpenStack/Outscale)
  pilotant des clusters enfants** via CAPI + Talos bootstrap/control-plane providers.
  Un enfant est injecté sans intervention manuelle (« gitception ») : Cilium (values
  alignées sur le socle) et Flux (`flux-gotk`) pilotés à distance via
  `spec.kubeConfig`, puis l'enfant réconcilie seul son profil `apps/flux/<profil>`.
  Validé en réel bout en bout : management/Scaleway + edge-2/OVH + edge-3/Outscale,
  les deux enfants sur le profil `workload` autonome.
- **providerID Talos ⇄ CCM** validé sur les 3 clouds (Scaleway/OVH/Outscale) : la CCM
  `talos-cloud-controller-manager` résout le nodeRef sans transformation, condition
  du fonctionnement de `MachineHealthCheck`.
- **Rolling upgrade Talos/K8s zéro coupure** prouvé en réel sur edge-2 (OVH) après
  correction d'un vrai trou de FIP de surge (`MACHINE_REV` + FIP surge dédiée dans
  `certSANs`/`preAllocatedFloatingIPs` — voir le header du template
  `cluster-talos-openstack/cluster.yaml`, repo apps).

### Added — observability + alerting bout en bout

- Stack VictoriaMetrics (vmagent/vmalert/vmselect/vminsert), 19 règles d'alerte,
  Alertmanager → Slack. Une alerte réelle livrée depuis un cluster Scaleway, et un
  `Watchdog` dont le SILENCE est le signal (dead-man's switch).
- etcd, Cilium, Flux et cert-manager scrapés ; `task check-alerts` vérifie côté
  cluster réel que chaque règle référence une métrique qui produit effectivement
  de la donnée (une règle sur une métrique muette ne s'affiche jamais comme en
  échec — voir « Traps » du backlog).

### Added — backup/DR cross-provider

- Brique `backup` (restic, chiffré côté client, 2 dépôts S3) + `task etcd-snapshot`
  (snapshot etcd via `talosctl`, chiffré gpg, poussé primary + replica) validés en
  réel cross-provider (Scaleway + OVH), buckets préexistants, escrow de mot de passe
  restic obligatoire.

### Changed — durcissement CI (les deux dépôts)

- Actions et hooks GitHub épinglés par SHA, branch rulesets, gate anti-collision
  d'objets Kustomize (`scripts/check-object-collisions.py`). CI verte sur
  `OpenAether-infra` et `OpenAether-apps`.

### Fixed — stabilité de `task up` / du cycle de vie complet (2026-07-31)

- **`task infra` n'écrase plus un cluster déjà bootstrappé.** Le compte de nœuds du
  module Talos était piloté par `var.talos_bootstrap`, donc chaque ré-exécution de
  `task up` (qui repasse toujours par `task infra`, `talos_bootstrap=false`) mettait
  ce compte à zéro et supprimait `talos_machine_bootstrap` de l'état — recréé
  ensuite par `bootstrap-phase2`, qui renvoyait la RPC de bootstrap contre un etcd
  déjà vivant (rejetée) et invalidait le kubeconfig local au passage. `task infra`
  détecte maintenant l'état existant avant de décider.
- **`edge-down.sh` vérifie réellement le nettoyage côté provider** au lieu de faire
  confiance à la seule disparition des objets Kubernetes (nouveau
  `scripts/ops/verify-provider-clean.py`, avec retries). Ce contrôle a immédiatement
  trouvé un troisième bug réel : une load balancer Octavia orpheline d'un teardown
  précédent, réutilisée par CAPO au déploiement suivant, cassait silencieusement le
  redeploy (port VIP disparu, 404). Corrigé en réel (suppression ciblée via le
  nouveau `scripts/ops/delete-openstack-resource.py`) et désormais détecté
  automatiquement.
- Les deux fixs validés sur un cycle complet réel : management fraîche → déploiement
  edge-2 (OVH) réel → teardown avec vérification provider → `fleet-down` complet →
  les 3 providers reconfirmés propres indépendamment.

---

## [0.4.0] — 2026-06-04

**Milestone: multi-cloud management + GitOps foundations, ready for external testers.**
The management cluster (Talos → Cilium → Flux → GitOps `ApplicationSet`) is now
validated end-to-end on **all three providers** (Scaleway, OVH, Outscale), and the
full cloud lifecycle — `task talos-image` → `infra-management` → `management` →
teardown — was re-run clean on each. The local Docker harness gained 2 workers
(3 CP + 2 schedulable workers) and the test/lint tooling was hardened. Not 1.0
yet (the platform stack on top — Gateway/Identity/Secrets/Observability — is still
Phase 2 and pending a service-mesh/gateway revision), but stable enough to test.

### Fixed — Outscale management cluster end-to-end (3/3 providers live)

Brought the Outscale management cluster to a working Talos bootstrap, completing
validated **management** deployments on all three providers (Scaleway ✅ ·
OVH ✅ · Outscale ✅). Fixes, in the order they surfaced:

- **Control-plane NIC** — control planes attach to the subnet directly; Outscale's
  CreateVm rejects a dedicated NIC together with the VM's security groups.
- **Bastion SSH user** — Outscale's official OMIs default to the `outscale` login,
  not `ubuntu`; `bastion_user` is now mapped per provider (scaleway/ovh/outscale).
- **Node internet egress** — the module had only an Internet Gateway, which 1:1-NATs
  instances that own a public IP. The cluster nodes have none, so NTP and the
  etcd/Kubernetes image pulls timed out and the bootstrap hung. Added a **NAT
  service** in an AWS-style two-subnet layout (private nodes → NAT, public
  bastion/NAT/LB → IGW), mirroring the Scaleway public-gateway / OVH router SNAT.
- **Tunnel host key** — `talos-tunnels.sh` clears the stale `known_hosts` entry
  before opening; a re-created bastion keeps its EIP but gets fresh host keys, which
  otherwise failed every tunnel with a host-key mismatch.
- **Worker certSANs** — the worker machine config now includes `127.0.0.1` (like the
  control plane), required because Phase 2 reaches every node through an SSH tunnel
  on localhost (was failing TLS verification with "valid for <node IP>, not 127.0.0.1").

### Fixed — Flux installed in the management-gitops namespace

`render-bootstrap-manifests.sh` now kustomizes the upstream Flux install into
`${FLUX_NAMESPACE:-flux-system}` (+ the Namespace, + the ClusterRoleBinding
subjects, which kustomize doesn't rewrite on its own). The namespace-agnostic
upstream manifest, injected as a Talos inlineManifest, was landing in `default` —
so Flux watched `default` while the root app lived in `management-gitops` and the
root Application never reconciled. Affects every provider's bootstrap.

The GitOps path (`apps/bootstrap/base`, which Flux self-manages from git) had
the same ClusterRoleBinding-subject gap: kustomize's `namespace:` transformer
left the 3 subjects in `Flux`, so the application-controller SA got no
cluster-scoped permissions and its live-state cache failed ("cannot list … at
the cluster scope"), pinning root apps at `SYNC Unknown`. Added a kustomize
patch to namespace those subjects too — otherwise a self-sync would revert the
inline-manifest fix above.

### Fixed — local Docker test harness (`test-talos-local.sh`)

- **`grep -c` footguns** — four `R=$(… | grep -c …)` counts aborted the script
  under `set -e`+`pipefail` the moment they matched zero lines (grep exits 1),
  silently killing the run at "etcd quorum"/"nodes Ready"/"Flux pods". Guarded
  with `|| true`; the etcd one also dropped a stray `|| echo 0` that produced a
  two-line `"0\n0"` and broke the arithmetic `[[ ]]`.
- **State hygiene** — `machine_secrets` is `prevent_destroy`'d, so `tofu destroy`
  (and `task local-down`) couldn't tear the local cluster down and left a stale
  state behind. Reusing it broke the next run: a skipped bootstrap (etcd hangs at
  "waiting to join") or an old CA against fresh containers (bootstrap TLS
  handshake failure). The script now wipes the ephemeral local state when no live
  cluster is present and in `--destroy`; `task local-down` delegates to
  `--destroy` for a real teardown (containers + volumes + network + state).

### Fixed — developer tooling

- **`task lint`** — `tflint --recursive <dir>` broke at tflint v0.47 (positional
  path args dropped) → `tflint --chdir=<dir> --recursive`. Documented the
  `encryption_passphrase` variable (its sole finding). `.yamllint` now ignores
  the generated `cilium-local.yaml` (twin of the already-ignored `cilium.yaml`).

### Added

- **Local cluster gains 2 dedicated workers** — the Docker test setup is now
  **3 CP + 3 workers** (`worker_count`, default 3) instead of 3 single-role CPs.
  Workers stay schedulable while the control planes keep their taint, so the
  local harness now covers HA and real pod scheduling. Worker Talos APIs map to
  `127.0.0.1:50010/50011`, node IPs `10.5.0.20/21`. `modules/providers/local`
  already supported workers; this wires them through `opentofu-local` and the
  test script (health `--worker-nodes`, 5-node checks, schedulable-worker check).
  To dodge Docker Desktop's WSL2 port-forwarder 500ing on concurrent `--publish`
  registrations, workers are created in a second wave (`depends_on` the control
  planes) and each `docker run` retries — no global `-parallelism=1` (which would
  deadlock the container-independent bootstrap).
- **`task destroy-management PROVIDER=…`** — symmetric with `destroy-workload`.

### Changed

- Provider names spelled out everywhere (`scw` → `scaleway`) in docs/env templates,
  consistent with the bucket/image naming convention.
- OVH defaults: region `EU-WEST-PAR` (3-AZ), node/bastion flavor `b3-8`.
- Outscale bastion downsized to `tinav5.c2r2p2`.

---

## [0.3.3] — 2026-06-03

### Changed — repository structure (Option A)

All OpenTofu code is now under `infrastructure/opentofu/`:

```
infrastructure/opentofu/
  cluster/        ← cluster root (was infrastructure/opentofu/ top-level)
  talos-image/    ← image builder root (was infrastructure/talos-image/)
  modules/        ← shared modules (unchanged)
```

No task names changed for the user. The `task talos-image`, `infra-management`,
`management`, `infra-workload`, `workload`, `failover` tasks still work identically —
only the `dir:` and script paths were updated internally.

### Changed — Talos image bucket naming

`task talos-image PROVIDER=scaleway` now uses bucket `s3-openaether-scaleway-talos-image`
(was `s3-openaether-scw-…`), consistent with OVH/Outscale which already used
the full provider name. Fixes a Scaleway async-delete bucket collision.

### Added — Talos image build for Outscale

`task talos-image PROVIDER=outscale` is now implemented:
`nocloud-amd64.raw.zst` → OOS staging → `outscale_snapshot` import (pre-signed URL,
`snapshot_size` in bytes, ~16 min) → `outscale_image` (OMI).

Key fixes along the way: AWS CLI v2.23+ trailing checksum (`when_required`),
`snapshot_size` in bytes (not GiB), pre-signed URL for Outscale auth, explicit
provider creds via `TF_VAR_outscale_*` (API == OOS keys for Outscale).

Validated images: Scaleway ✅ · OVH ✅ · Outscale ✅.

---

## [0.3.2] — 2026-06-02

### Changed — backup & DR storage model (client-side encryption + dual store)

Every DR artifact now lives in **two** object stores — a **primary** (the
cluster's own provider) and a **replica** (`-backup`; in prod a *different*
provider, different creds) — and is **client-side encrypted** before it ever
reaches storage.

### Added

- **Client-side encrypted artifact backups** — `scripts/backup-artifacts.sh`
  encrypts talosconfig/kubeconfig with **gpg `--symmetric` AES-256** (authenticated,
  hardened S2K) using the same `encryption_passphrase` as the tfstate, then uploads
  to the primary **and** replica stores with S3 SSE on top. Replaces the previous
  SSE-only (server-side) backup.
- **tfstate replication** — `scripts/backup-state.sh` copies the already
  client-encrypted state (AES-GCM) to the `-backup` store after each apply (the
  backend only flushes state on apply exit, so this is a post-apply step). Wired
  into the cluster tasks + a standalone `task backup-state`.
- **Per-cluster encrypted state** — the S3 backend is now **partial**
  (`backend.tf`); its bucket/key/region/endpoint are **derived from the cluster's
  tfvars** by `scripts/tf-backend.sh` (single source of truth, so dev/prod never
  drift — no separate backend file). Each cluster gets its own state following
  `s3-<project>-<provider>-tfstate-<env>` (key `<cluster_name>.tfstate`).
  Artifacts follow `s3-<project>-<provider>-<role>-<env>`.
- **Cross-provider backup creds** — `BACKUP_AWS_ACCESS_KEY_ID` /
  `BACKUP_AWS_SECRET_ACCESS_KEY` for the replica store (default to the primary
  `AWS_*` in dev). `setup.sh` now installs/checks `gpg` + `jq`.
- **Bucket auto-provisioning** — `scripts/ensure-buckets.sh` derives the bucket
  names from a cluster's tfvars and creates any that are missing (idempotent),
  wired into `task infra-management` / `infra-workload` before `tofu init` (the
  S3 backend doesn't create its own bucket). Only the **state primary** bucket is
  required pre-`init` (fatal); the backups are best-effort and never block deploy.
- **Provider in the bucket names** — convention is now
  `s3-<project>-<provider>-{tfstate|<role>}-<env>(-backup)` (provider explicit,
  derived from the active provider), consistent across management and workload.
- **Provider-generic management & failover** — `task infra-management` /
  `management` now take `PROVIDER` (scaleway/ovh/outscale), like the workload tasks.
  Full env matrix added: `management-{scaleway,ovh,outscale}`,
  `failover-{scaleway,ovh,outscale}` (each a `.tfvars.example`).
  A `failover-*` cluster is the **cross-provider failover** (a second management
  on another cloud) — distinct from the everyday recovery of re-applying your own
  `management-<provider>` on the same provider.

### Renamed

- **`drp-*` → `failover-*`** to match what it is: a *second* management cluster on
  a **different** cloud (provider loss), not the everyday disaster recovery (which
  is just re-applying your own `management-<provider>`). `scripts/drp-management.sh`
  → `scripts/failover-management.sh`, `task drp` → `task failover`,
  `envs/drp-*` → `envs/failover-*`.

### Removed

- Dead `aws` provider + `backup_s3_{endpoint,region,bucket}` variables (the
  backup path is CLI-only now). New inputs: `s3_primary_{endpoint,region}` and
  `s3_replica_{endpoint,region}`; bucket names are derived from the convention.

### Documented

- Backup/restore (DR) procedure — decrypting a backed-up artifact with the same
  passphrase; recovering state from the `-backup` store.

---

## [0.3.1] — 2026-06-01

### Validated — first end-to-end cloud deployment (Scaleway)

The management cluster stack came up on Scaleway (3 control planes + 2 workers,
Cilium, Flux, GitOps), exercising the two cloud-only Talos resources that local
Docker can't: `talos_machine_configuration_apply` (gRPC) and
`data.talos_cluster_health`. Changes that got it there:

### Added

- **Block-storage Talos image** — the image builder now imports the QCOW2 as a
  `scaleway_block_snapshot` per zone and builds a block-backed image (boots
  current-gen PRO2/POP2; l_ssd/DEV1 is a deprecated, zone-limited dead-end).
- **Auto SSH tunnels for Phase 2** — `scripts/talos-tunnels.sh` reads node IPs
  from the state and opens one tunnel per node via the bastion; wired into the
  `management` / `workload` tasks (`task close-tunnels` to tear down).
- **CLI-based encrypted S3 backup** (`terraform_data` + `aws s3 cp`, SSE-S3) for
  talosconfig/kubeconfig — replaces `aws_s3_object`, which hits a `version_id`
  plan-inconsistency bug on S3-compatible stores.

### Fixed / Security

- **Bastion hardening** — dedicated unprivileged `bastion` SSH user (root login
  and password auth disabled) instead of `root`.
- **Bastion public-IP routing** on the NAT'd VPC — a root systemd unit stops the
  VPC-pushed default route from hijacking the bastion's inbound SSH.
- **Single-cloud applies** no longer require other providers' credentials
  (OpenStack `auth_url` placeholder when OVH is inactive).
- **Plan-known node counts** — gate count/for_each on `node_distribution` counts
  rather than apply-unknown private IPs (Phase 1 and Phase 2 both plan cleanly).
- **Phase-2 connectivity** — feed the talos module per-node tunnel endpoints
  (CPs `127.0.0.1:5000+i`, workers `5010+i`).

### Documented

- Manual teardown procedure (`state rm` the PKI-protected secrets +
  `-var talos_bootstrap=false` to skip the tunnel-bound health check).

---

## [0.3.0] — 2026-05-30

### Added — Local 3-CP Talos test harness (Docker)

- **`infrastructure/opentofu-local/`** — standalone OpenTofu root (no S3 backend) that drives the **production `modules/talos/`** to stand up a real **3 control plane** Talos cluster in Docker.
- **`modules/providers/local/`** — Docker-based provider (terraform_data + Docker CLI, no Docker provider dependency): N containers on a dedicated `10.5.0.0/24` network with static IPs, `--read-only`, `PLATFORM=container`, the full Talos volume set, and config injected via `USERDATA`. Implements the provider contract with a node-IP / host-endpoint split (`127.0.0.1` port mappings for WSL2).
- **`modules/talos/` enhancements (backward-compatible, cloud unchanged):**
  - `config_delivery` (`apply` cloud / `userdata` Docker) — Docker uses USERDATA injection per the Talos platform docs (maintenance-apply reboot-loops in containers).
  - `control_plane_endpoints` / `worker_endpoints` — reach nodes via port mappings while keeping container IPs as node identity (etcd/certSANs).
  - `container_mode` — omits `machine.install` and enables `hostDNS.forwardKubeDNSToHost`.
  - `health_check_timeout`, `skip_kubernetes_health_checks`, `skip_health_check` — robustness knobs.
  - New outputs `control_plane_machine_configs` / `worker_machine_configs` (consumed for USERDATA).
- **`scripts/test-talos-local.sh`** — single-command E2E: config gen → 3 USERDATA containers → etcd quorum bootstrap → kubeconfig → Cilium (3 nodes) → Flux → ApplicationSet.
- **`render-bootstrap-manifests.sh --local`** — simplified Cilium (no WireGuard, no kube-proxy replacement) for Docker.
- **Taskfile** `local-*` tasks.
- **Validated end-to-end**: 3 nodes `Ready` on Kubernetes v1.35.3, **3-member etcd quorum**, Cilium CNI on all nodes, tofu-retrieved kubeconfig, Flux running, and the ApplicationSet generating the management cluster's Application.
- **Coverage**: 7 of 8 `modules/talos/` resources are exercised locally; only `talos_machine_configuration_apply` and the `talos_cluster_health` data source are cloud-only (both for legitimate platform/networking reasons).

### Added

**Multi-cloud CMP infrastructure (Phase 3):**
- **OVH / OpenStack module** — complete networking stack (private network, router, Octavia LBs, floating IPs, bastion)
- **Outscale / Numspot module** — VPC, subnets, load balancers, public IPs, bastion
- **Provider-agnostic junction point** — `coalesce()` selects the active provider; adding a new provider requires only implementing the contract
- **`cluster_role` variable** — `management` or `workload` routes Flux to the correct overlay
- **Per-cluster environment templates** — `envs/management-scaleway.tfvars.example`, `envs/workload-{scaleway,ovh,outscale}.tfvars.example`, `envs/drp-ovh.tfvars.example` (copy to the real `*.tfvars`, which stays git-ignored)
- **Single-provider validation** — `check` block prevents accidentally activating multiple providers in one apply

**GitOps multi-cluster:**
- **Flux ApplicationSet** — replaces single root Application; automatically deploys the correct overlay to each registered cluster
- **Management cluster overlay** — `apps/overlays/management/` (OpenBao, Keycloak, VictoriaMetrics, etc.)
- **Workload cluster overlay** — `apps/overlays/workload-base/` (Traefik, ESO, Kyverno, KEDA, storage)
- **Local cluster secret** — management cluster registers itself in Flux hub on bootstrap

**Operational tooling:**
- **`scripts/register-spoke.sh`** — registers a workload cluster in Flux hub after provisioning
- **`scripts/drp-management.sh`** — automated DRP procedure; rebuilds management cluster on fallback provider (~30 min RTO)
- **`scripts/test-local-stack.sh`** — full local validation (OpenTofu tests + kustomize builds + talosctl + yamllint) with no cloud credentials required
- **Taskfile** — new tasks: `deploy-management`, `deploy-workload`, `bootstrap-workload`, `register-spoke`, `drp`

**Testing (26 unit tests):**
- `tests/scaleway.tftest.hcl` — 9 tests (SCW module, provider contract, multi-provider activation)
- `tests/talos-config.tftest.hcl` — 10 tests (certSANs, bootstrap logic, version format, cluster role)
- `tests/provider-contract.tftest.hcl` — 7 tests (junction point behavior, all 3 providers, safe defaults)

**CI enhancements:**
- OpenTofu tests run all 3 test suites
- Kustomize build validation for all 6 overlays
- Talos config generation and validation via `talosctl`

### Changed

- `node_distribution` variable extended with OVH/Outscale-specific optional fields (`flavor_name`, `availability_zones`, `network_name`, `bastion_image_id`)
- `outputs.tf` — all outputs are now provider-agnostic; added `active_provider` and `cluster_role`
- `Flux-root-app.yaml.tftpl` — now points to `apps/bootstrap/overlays/prod/` instead of a single overlay path
- `apps/overlays/local/` — removed deprecated Linkerd (replaced by Cilium Service Mesh, Phase 4)
- YAML lint config — added ignore patterns for vendor/generated files; relaxed sequence indentation rule

### Fixed

- `apps/base/namespaces/` — missing `kustomization.yaml` (kustomize build was failing)
- `apps/base/kyverno-policies/` — missing `kustomization.yaml`
- `apps/base/openbao/statefulset.yaml` — indentation errors
- `apps/base/openbao/httproute.yaml` — indentation errors
- `apps/base/traefik/rbac-gateway.yaml` — lines exceeding 120 chars
- Grafana — disabled anonymous admin access (was `GF_AUTH_ANONYMOUS_ENABLED=true`)

### Updated (versions)

| Component | Before | After |
|-----------|--------|-------|
| VictoriaMetrics | v1.93.0 | v1.102.0 |
| Grafana | 10.0.0 | 11.2.0 |
| OpenBao | 2.0.0 | 2.2.0 |
| KEDA | v2.12.0 | v2.15.1 |
| Kyverno | v1.10.0 | v1.12.0 |
| kubectl (Kyverno CronJob) | v1.28.2 | v1.33.0 |
| busybox (storage) | unpinned | 1.36.1 |

---

## [0.2.0] — 2026-02-01

- **Secure Remote Management**: Encrypted S3 Backend for Tofu state (Client-Side Encryption, AES-GCM).
- **Automated SSE-C Backups**: Secure artifact backup (`kubeconfig`, configurations) to S3.
- **Zero-Trust Networking**: Refactored LB ACLs (admin IP + NAT GW hairpinning).
- **Scaleway Deployment**: First provider deployed and validated in HA environment.
- **Zero-Local Policy**: No persistent local configuration files.

### Infrastructure

- Scaleway: Security Groups with zonal segmentation.
- Scaleway: Hybrid zone support for `DEV1-S` / `PRO2` instance types.

---

## [0.1.0] — 2025-12-31

- Multi-provider architecture (Outscale, Scaleway)
- Talos Linux v1.9.1, Pulumi (Go) IaC
- Cilium CNI auto-deployment
- Taskfile automation
- GitOps structure prepared (`apps/`)
