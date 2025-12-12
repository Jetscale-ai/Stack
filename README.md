# JetScale Stack

The central infrastructure, deployment, and orchestration repository for the JetScale Platform.

## 🚀 The Vision

We run JetScale on a **"Platform-First"** model.
Instead of a drifting `docker-compose`, this repo enables **Live-like environments locally** via:

- **Tilt** → Local Dev (hot reload, dev images)
- **Skaffold + Kind** → Local E2E (Alpine runtime parity)
- **Helm + OCI** → Immutable, versioned deployment artifacts

## 3. The Sovereign Boundary (Architecture)

To ensure our Helm chart remains **Cloud Agnostic** (deployable on AWS, Azure, or On-Prem), we adhere to a strict separation of concerns:

| Layer | Owner | Responsibilities |
| :--- | :--- | :--- |
| **Infrastructure** | **Terraform** | **The "Hardware" & "Drivers":** VPC, EKS, RDS, Redis, **AWS LB Controller**, **ExternalDNS**, **External Secrets Operator**. |
| **Application** | **Helm** | **The "Intent":** `Ingress` resources, `ExternalSecret` mappings, Deployments, Services. |

**The Contract:** Terraform provides the "Pipe" (SecretStore, Ingress Class, DNS automationggggg); Helm turns on the "Tap" (ExternalSecret, Ingress Resource).

## 4. The 5-Stage Lifecycle

| Stage | Loop Name | Tooling | Environment | Strategy |
| :-- | :-- | :-- | :-- | :-- |
| **1** | **Inner Loop** | Tilt | Kind (Local) | **Speed.** Hot reload, fat images. |
| **2** | **Outer Loop** | Skaffold | Kind (Local) | **Parity.** Builds local code -> Alpine images. |
| **3** | **CI Loop** | Skaffold | Kind (CI Runner) | **Gating.** Deploys remote OCI artifacts. |
| **4** | **Preview Loop** | TF + Helm | **Ephemeral EKS** | **Isolation.** "Cluster-per-PR". Fresh infra, fresh data, destroy on close. |
| **5** | **Live Verify** | TF + Helm | **Live EKS** | **Availability.** Persistent infra, rolling updates, schema migrations. |

## 🛠️ Quick Start (Local Dev)

### 1. Prerequisites

- **Docker**
- **Kind**: `go install sigs.k8s.io/kind@latest`
- **Tilt**: `curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash`
- **Helm**: `brew install helm`
- **Mage**: `go install github.com/magefile/mage@latest`

### 2. Boot the Local Dev Platform (Inner Loop)

Run these commands from the `stack/` directory:

```bash
# 1. Create the local cluster
kind create cluster --config kind/kind-config.yaml --name kind

# 2. Authenticate (Required for OCI Charts)
gh auth login --scopes read:packages
gh auth token | helm registry login ghcr.io --username $(gh api user -q .login) --password-stdin

# 3. Vendor chart dependencies (From OCI)
(cd charts/app && helm dependency build)

# 4. Start Dev Loop (Fat images + Hot Reload)
tilt up
```

## 📂 Repository Layout

- `charts/app` — **The Definition (Sovereign).** The generic "Umbrella Chart". Dependencies are pinned to immutable OCI versions.
- `envs/` — **The Instantiation.**
  - `envs/live/values.yaml` → Production (HA, replication).
  - `envs/preview/values.yaml` → Ephemeral (Cluster-per-PR settings).
- `clients/` — **The Infrastructure (Terraform).**
  - Defines the AWS resources for both Live and Ephemeral tenants.

## 🧙‍♂️ Mage Tasks

```bash
mage validate:envs     # Check structural integrity of all envs/
mage test:locale2e     # Run Stage 2 (Local Parity)
mage test:ci           # Run Stage 3 (CI Mode)
```
