# 🌐 OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Internal Developer Platform (IDP).

## 🏗️ Architecture

OpenAether uses **Talos Linux** and a "Zero Trust" sovereign stack:

*   **Infrastructure**: Pulumi (Go)
*   **OS**: Talos Linux (Immutable, Secure)
*   **Gateway**: Traefik (Gateway API)
*   **Identity**: Keycloak (OIDC/SAML) + CloudNativePG (HA Postgres)
*   **Service Mesh**: Linkerd (mTLS everywhere)
*   **Secrets**: OpenBao (Vault Fork)
*   **Policy**: Kyverno (Policy as Code)
*   **Observability**: VictoriaMetrics (Metrics), Loki (Logs), Grafana (UI)

## 📂 Repository Structure

*   `infrastructure/` - **Pulumi Go Code**. Defines the infrastructure components (Clusters, Networking).
*   `clusters/` - **Talos Configs**. Machine configurations.
*   `apps/` - **Kustomize Structure**.
    *   `base/` - Core components (Gateway, Linkerd, etc.).
    *   `overlays/` - Environment specific (local, prod).

## 🚀 Quick Start

### Prerequisites
Run the setup script:
```bash
bash scripts/setup.sh
```
*Note: You may need `sudo modprobe br_netfilter` on your host for local Docker networking.*

### 1. Configure Pulumi (Local Backend)
```bash
pulumi login --local
```

### 2. Start Local Simulation (Talos-in-Docker)
Spin up a local Talos node using Pulumi:
```bash
task local:up
```

### 3. Deploy Platform (DevSecOps Stack)
Deploy the entire stack (Gateway, IAM, Mesh, Apps) to the local cluster:
```bash
task deploy:local
```

Access services via `*.localhost` (automatically mapped by Chrome/Firefox or add to `/etc/hosts`):
*   **Demo App**: [http://demo.localhost](http://demo.localhost)
*   **Keycloak**: [http://auth.localhost](http://auth.localhost)
*   **Grafana**: [http://grafana.localhost](http://grafana.localhost)

## 🛡️ Security

*   **Secrets**: Managed via **OpenBao**.
*   **Network**: mTLS enabled by default via **Linkerd**.
*   **Policies**: **Kyverno** enforces Pod Security Standards (Audit mode default).

## 🔧 Troubleshooting

### `Failed to check br_netfilter`
If pods (specifically `kube-flannel`) crash with this error:
1.  Run `sudo modprobe br_netfilter` on your host.
2.  Restart: `task local:down && task local:up`.

## 📜 License

**OpenAether** is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

### Source Code

The complete source code is available at: **https://github.com/dis-bzh/OpenAether**

If you use this software as a service (SaaS), you must:
- Provide a link to the exact source code version you are running
- Include all your modifications in the published source

### Third-Party Components

OpenAether uses the following open-source components, all compatible with AGPLv3:

| Component | License |
|-----------|---------|
| Pulumi | Apache 2.0 |
| Talos Linux | MPL 2.0 |
| Keycloak | Apache 2.0 |
| OpenBao | MPL 2.0 |
| Linkerd | Apache 2.0 |
| Traefik | MIT |
| cert-manager | Apache 2.0 |
| Cilium | Apache 2.0 |
| Grafana Stack | AGPLv3 |

