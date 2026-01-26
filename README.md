# JetScale Stack

The Helm **umbrella chart** (and local dev orchestration) for the JetScale Platform.

**Important:** This repository produces an **immutable OCI Helm artifact**. It does **not** own deployment state.

- **State & version pins:** `../fleet/`
- **Installation patterns (Blueprints):** `../catalog/`

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

**The Contract:** Terraform provides the "Pipe" (SecretStore, Ingress Class, DNS automation); Helm declares the "Tap" (ExternalSecret, Ingress Resource).

## 4. The 5-Stage Lifecycle

| Stage | Loop Name | Tooling | Environment | Strategy |
| :-- | :-- | :-- | :-- | :-- |
| **1** | **Inner Loop** | Tilt | Kind (Local) | **Speed.** Hot reload, fat images. |
| **2** | **Outer Loop** | Skaffold | Kind (Local) | **Parity.** Builds local code -> Alpine images. |
| **3** | **CI Loop** | Skaffold | Kind (CI Runner) | **Gating.** Deploys remote OCI artifacts. |
| **4** | **Preview Loop** | TF + ArgoCD | **Ephemeral EKS** | **Sovereignty.** Cluster-per-PR + GitOps sync from `../fleet`. |
| **5** | **Live Verify** | TF + ArgoCD | **Live EKS** | **Availability.** Persistent infra + GitOps upgrades via `../fleet`. |

## 🚀 Pull Request Workflows

### Launching an Ephemeral Environment

To save costs, Preview environments are **manual-trigger only**.

1. **Open a Pull Request.**
2. **Add the label:** `preview`.
3. **Wait (~15m):** The `Ephemeral Fleet` action will provision a full EKS cluster.
4. **Access:** A bot will comment with the link: `https://pr-123-feat-x-unstable.jetscale.ai`.

> **Note:** This check is a **Mandatory Gate** for merging to `main`.

- Architecture: `docs/ephemeral-architecture.md`

### The Janitor (Auto-Cleanup)

When a PR is **closed** or **merged**, the `Janitor` workflow automatically destroys the cluster.

- **Manual Fallback:** If the Janitor fails, you can manually trigger the `Ephemeral Fleet` workflow with **Action: destroy**.

## 📦 Release Workflow

This repository is the **Source of Truth** for the Application Code, but **NOT** the Deployment State.

### How to Deploy

1. **Build:** CI packages and pushes the `jetscale` chart to `oci://ghcr.io/jetscale-ai/charts` (version `X.Y.Z`).
2. **Deploy:** Go to `../fleet`, find your cluster, and update `clusters/<name>/values.yaml`:
   - `versions.stack: X.Y.Z`
3. **Sync:** ArgoCD detects the change in Fleet and pulls the OCI artifact from here.

### Local Development (Tilt)

Tilt still uses this directory directly for the Inner Loop.

### Legacy Deployment (Pre-ArgoCD)

For historical reference:

- Runbook: `docs/live-deploy.md`
- Script: `scripts/deploy-live.sh`

## 🛠️ Quick Start (Local Dev)

### 1. Prerequisites

- **Docker**
- **ctlptl**: `go install github.com/tilt-dev/ctlptl/cmd/ctlptl@latest` (for local Kubernetes clusters with registry)
- **Kind**: `go install sigs.k8s.io/kind@latest`
- **Tilt**: `curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash`
- **Skaffold**: `curl -fsSL https://raw.githubusercontent.com/GoogleContainerTools/skaffold/main/install-skaffold.sh | bash`
- **Helm**: `brew install helm`
- **Mage**: `go install github.com/magefile/mage@latest`

### 1.5. Cluster Setup (Required for local dev)

Local development uses a Kind cluster wired to a local registry via `ctlptl`. This is required for
both `tilt up` and `mage test:localE2E`.

```bash
ctlptl apply -f kind/ctlptl-registry.yaml
```

This creates a local registry at `localhost:5000` that caches Docker images and keeps image pulls fast.

### 2. Boot the Local Dev Platform (Inner Loop)

#### Helm/Container Registry Github auth

Documentation: <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry>

To use the OCI published Helm charts and GHCR images by our pipelines, we need to auth. our CLIs

1. Create a classic PAT with those minimal permissions:
   - read:packages
2. [HELM] Login with your username: `helm registry login ghcr.io --username <USERNAME>`
3. [Docker] Login with your username: `docker login ghcr.io --username <USERNAME>`

#### How-tos

Run these commands from the `Stack/` directory (root of this repo):

```bash
# 1. Create the local cluster
kind create cluster --config kind/kind-config.yaml --name kind
# If you already have a customized .kube/config, you can pass the argument --kubeconfig string for a specific location.

# 2. Authenticate to GHCR (Required for private OCI chart dependencies)
# Option A (recommended): create a gitignored `.env` with:
#   GITHUB_TOKEN=<token with read:packages>
# Then `mage validate:envs` will automatically login + build deps.
#
# Option B (GitHub CLI):
#   gh auth login --scopes read:packages
#   gh auth token | helm registry login ghcr.io --username $(gh api user -q .login) --password-stdin

# 3. Validate (also builds chart deps)
mage validate:envs aws

# 4. Start Dev Loop (Fat images + Hot Reload)
tilt up
```

## 📂 Repository Layout

- `charts/jetscale` — **The Definition (Sovereign).** The generic "Umbrella Chart". Dependencies are pinned to immutable OCI versions.
- `envs/` — **The Instantiation.**
  - All `.yaml` and `.yml` files in subdirectories are automatically validated.
  - See [envs/](envs/README.md) documentation

## 🧙‍♂️ Mage Tasks

```bash
mage validate:envs aws    # Check structural integrity of all YAML files in envs/
mage test:locale2e     # Run Stage 2 (Local Parity)
mage test:ci           # Run Stage 3 (CI Mode)
```
