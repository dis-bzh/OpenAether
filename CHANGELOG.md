# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-12-31

### Added

- **Multi-provider architecture** with `ProviderRegistry` for extensible cloud support
- **Docker provider** for local development (Talos-in-Docker)
- **Outscale provider** for 3DS sovereign cloud (EU)
- **Scaleway provider** for EU sovereign cloud
- **Cilium CNI** auto-deployment after cluster bootstrap
- **Taskfile automation** for deploy/destroy/preview workflows
- **Multi-environment support** via `.env.{local,test,prod}` files
- **Outscale Go SDK** integration for native API access

### Infrastructure

- Talos Linux v1.9.1 as immutable Kubernetes OS
- Pulumi (Go) for Infrastructure as Code
- Environment-based configuration system
- HAProxy load balancer for Docker provider

### Security

- All secrets excluded via `.gitignore`
- Talos API over mTLS
- Kubernetes API secured with generated certificates

### Documentation

- Updated README with provider matrix and quick start
- GitOps structure in `apps/` (prepared for Phase 2)

---

## [Unreleased]

### Planned

- OVH provider (OpenStack-based)
- ArgoCD bootstrap for GitOps
- Traefik Gateway API integration
- Keycloak + CloudNativePG for identity
- Linkerd service mesh
- OpenBao secrets management
- VictoriaMetrics + Loki + Grafana observability stack
