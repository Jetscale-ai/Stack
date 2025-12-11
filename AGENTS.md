# The JetScale Stack Constitution

## 1. Identity & Purpose

This repository, `Jetscale-ai/Stack`, is the **Sovereign Assembly** of the JetScale platform. It replaces the legacy `docker-compose.yml` as the single source of truth for system assembly.

## 2. The Golden Path (Dev Loop)

We represent a shift from "Container Orchestration" (Docker Compose) to "Platform Orchestration" (Helm + Kubernetes).

| Feature          | Old Way (Compose) | New Way (Stack)            |
| :--------------- | :---------------- | :------------------------- |
| **Orchestrator** | Docker Compose    | Tilt + Kind                |
| **Networking**   | Docker Bridge     | K8s Ingress / Service Mesh |
| **Config**       | `.env` files      | Helm `values.yaml`         |
| **Artifacts**    | `build: .`        | Immutable OCI Charts       |

## 3. Operational Invariants

### 3.1. Supply Chain Integrity (Logos/Prudence)

- **Immutable Artifacts:** `Chart.yaml` must point to versioned OCI repositories (`oci://`). Local paths (`file://`) are permitted only during active debugging ("Link Mode") and must never be committed to `main`.
- **Lockfile Primacy:** `Chart.lock` is the cryptographic ledger of our supply chain. It must be committed and synchronized with `Chart.yaml`.

### 3.2. Structural Integrity (Vigor)

- **Validation First:** No configuration shall be committed without passing `mage validate:envs`. This ensures `envs/` configurations always align with `charts/` schemas.
- **Environment Parity:** The `charts/app` definition is universal. Environments (`envs/`) differ only in configuration (values), never in structure (templates).

### 3.3. Public by Default (Ethos)

- This repo is public. No secrets (API keys, passwords) shall ever be committed. Secrets are injected via External Secrets Operator or local `.env` overrides (gitignored).

### 3.4. The Sovereign Boundary (Autonomy)

- **Chart Agnosticism:** The Helm chart must remain "Platform Agnostic." It declares _intent_ (e.g., standard `Ingress` resources, `ExternalSecret` references), never _implementation_ (e.g., AWS ALB creation logic, Route53 updates).
- **Infrastructure Responsibility:** The Infrastructure layer (Terraform/OpenTofu) is responsible for installing the "Drivers" that fulfill the Chart's intent. The Chart does not care _how_ the Ingress is fulfilled, only that it _is_.
- **The "Client Rule":** We never force a client to perform manual infrastructure work to install our App. The Chart is a self-contained deployable unit.
- **Multi-Cloud Portability:**
  - **AWS (SaaS):** Infra installs **AWS LB Controller** + **ExternalDNS**. The Chart's `Ingress` becomes an ALB.
  - **Azure (AKS):** Infra installs **AGIC** (App Gateway Ingress Controller) or **Nginx**. The _same_ Chart's `Ingress` becomes an Azure App Gateway.
  - **OpenStack/On-Prem:** Infra installs **Octavia** or **MetalLB**. The _same_ Chart's `Ingress` becomes a LoadBalancer IP.

## 4. The Eudaimonia Framework

All architectural decisions must be justified by the 12 Invariants:
_Ethos (Identity), Logos (Reason), Praxis (Action)._
