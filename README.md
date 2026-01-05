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
| **4** | **Preview Loop** | TF + Helm | **Ephemeral EKS** | **Sovereignty.** Full "Cluster-per-PR" in Live AWS Account. |
| **5** | **Live Verify** | TF + Helm | **Live EKS** | **Availability.** Persistent infra, rolling updates. |

## 🚀 Pull Request Workflows

### Launching an Ephemeral Environment
To save costs, Preview environments are **manual-trigger only**.

1. **Open a Pull Request.**
2. **Add the label:** `preview`.
3. **Wait (~15m):** The `Ephemeral Fleet` action will provision a full EKS cluster.
4. **Access:** A bot will comment with the link: `https://pr-123-feat-x-unstable.jetscale.ai`.

> **Note:** This check is a **Mandatory Gate** for merging to `main`.

### The Janitor (Auto-Cleanup)
When a PR is **closed** or **merged**, the `Janitor` workflow automatically destroys the cluster.
* **Manual Fallback:** If the Janitor fails, you can manually trigger the `Ephemeral Fleet` workflow with **Action: destroy**.

## Live deployment (Helm-only; ArgoCD later)

Live (`console.jetscale.ai`) is deployed **via Helm** (and later **ArgoCD**) using the same umbrella chart + values contract.
Skaffold is intentionally scoped to **Kind** workflows (local + CI E2E).

- Runbook: `docs/live-deploy.md`
- Script: `scripts/deploy-live.sh`
- CI/CD: **Stage 6** will redeploy Live on `envs/live/**` changes without forcing a new chart version (decoupled deploy).

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

# 2. Authenticate to GHCR (Required for private OCI chart dependencies)
# Option A (recommended): create a gitignored `.env` with:
#   GITHUB_TOKEN=<token with read:packages>
# Then `mage validate:envs` will automatically login + build deps.
#
# Option B (GitHub CLI):
#   gh auth login --scopes read:packages
#   gh auth token | helm registry login ghcr.io --username $(gh api user -q .login) --password-stdin

# 3. Validate (also builds chart deps)
mage validate:envs

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
