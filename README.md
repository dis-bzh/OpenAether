# 🌐 OpenAether

> **Store Anywhere, Run Anywhere.**
> An open-source, resilient, multi-cloud Internal Developer Platform (IDP).

## 🏗️ Architecture

OpenAether follows a **Hub & Spoke** architecture powered by **Talos Linux** and **Pulumi**.

*   **Infrastructure**: Pulumi (Go)
*   **OS**: Talos Linux (Immutable, Secure)
*   **GitOps**: ArgoCD
*   **UI**: Backstage
*   **Observability**: Prometheus / Grafana / OpenCost

## 📂 Repository Structure

*   `infrastructure/` - **Pulumi Go Code**. Defines the infrastructure components (Clusters, Networking).
*   `clusters/` - **Talos Configs**. Machine configurations for the Control Plane (Hub).
*   `apps/` - **ArgoCD Manifests**. "App of Apps" pattern for deploying services (Backstage, Monitoring, etc.).

## 🚀 Quick Start

### Prerequisites
### Prerequisites
Run the setup script to check/install required tools (Go, Docker, Pulumi, Task, Talosctl):
```bash
bash scripts/setup.sh
```
*Restart your shell if new tools were installed.*

### 1. Configure Pulumi (Local Backend)
Store infrastructure state locally (no account required):
```bash
pulumi login --local
```

### 2. Run Tests (with Mocks)
Verify the infrastructure logic without cloud credentials:
```bash
cd infrastructure
task deps
task test
```

### 2. Start Local Simulation (Talos-in-Docker)
Spin up a local Talos node using Pulumi (Docker Provider + Talos Provider):
```bash
task local:up
```
*This runs `pulumi up` to provision the container, generate configuration, and bootstrap the cluster.*
*You will see the `kubeconfig` in the Stack Outputs.*

### 3. Deploy to Cloud (Scaleway/OVH)
1.  Set your credentials (e.g., `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`).
2.  Edit `infrastructure/main.go` to set `CloudProvider: "scaleway"`.
3.  Run:
    ```bash
    pulumi up
    ```

## 🛡️ Security

*   **Secrets**: Managed via **HashiCorp Vault** + **External Secrets Operator**.
*   **Policies**: Enforced by Pulumi Policy as Code.
*   **Compliance**: ISO-ready (Immutable OS).
