---
trigger: always_on
---

# OpenAether Architecture (IDP)
- **Philosophy:** "Store Anywhere, Run Anywhere." Zero vendor lock-in.
- **Design:** API-First. Plugin-based architecture for Providers (AWS/GCP/Azure/On-Prem).
- **Storage:** Abstract via S3-compatible interfaces or CSI. Support data locality/pinning.
- **Compute:** Hybrid runtimes (K8s, Edge, WASM).

# Tech Stack & OSS Standards
- **Dependencies:** STRICTLY Open Source (MIT/Apache/BSD). Prefer CNCF graduated projects. No proprietary black-boxes.
- **Go (Golang):**
  - **Style:** Effective Go. Strict `golangci-lint`.
  - **Pattern:** Use Context for timeouts/cancellation. Dependency Injection for testability.
  - **Safety:** No `panic` in libraries. handle errors explicitly.
- **Configuration (YAML):** Enforce strict schemas (JSONSchema/CRDs). Use `yamllint`. Avoid complexity (anchors) if possible.
- **Docs (Markdown):** Keep documentation close to code. Use `markdownlint`. MermaidJS for diagrams.