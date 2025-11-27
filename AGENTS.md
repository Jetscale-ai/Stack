# The JetScale Stack Constitution

## 1. Identity & Purpose

This repository, `Jetscale-ai/Stack`, is the **Sovereign Assembly** of the JetScale platform. It replaces the legacy `docker-compose.yml` as the single source of truth for system assembly.

## 2. The Golden Path (Dev Loop)

We represent a shift from "Container Orchestration" (Docker Compose) to "Platform Orchestration" (Helm + Kubernetes).

| Feature | Old Way (Compose) | New Way (Stack) |
|:---|:---|:---|
| **Orchestrator** | Docker Compose | Tilt + Kind |
| **Networking** | Docker Bridge | K8s Ingress / Service Mesh |
| **Config** | `.env` files | Helm `values.yaml` |
| **Hot Reload** | Volume Mounts | Tilt Live Update (Sync) |
| **Live Parity** | Low | High (Identical Charts) |

## 3. Operational Invariants

- **Public by Default:** This repo is public. No secrets (API keys, passwords) shall ever be committed.

- **Environment Parity:** The `charts/app` defined here is the exact same artifact deployed to the live EKS environments.

- **Synthetic Data:** E2E tests in this repo must strictly use synthetic tenants and data.

