# JetScale Stack

The central infrastructure, deployment, and orchestration repository for the JetScale Platform.

## 🚀 The Vision

We run JetScale on a **"Platform-First"** model.  
Instead of a drifting `docker-compose`, this repo enables **Live-like environments locally** via:

- **Tilt** → Local Dev (hot reload, dev images)
- **Skaffold + Kind** → Local E2E (Alpine runtime parity)
- **Helm** → Single unified deployment surface for all environments

This produces a consistent experience across Dev → CI → Preview → Live.

## 🛠️ Quick Start (Local Dev)

### 1. Prerequisites

- **Docker**
- **Kind**: `go install sigs.k8s.io/kind@latest`
- **Tilt**:  
  `curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash`
- **Helm**: `brew install helm`

### 2. Boot the Local Dev Platform (Inner Loop)

Run these commands from the `stack/` directory:

```bash
# 1. Create the local cluster
kind create cluster --config kind/kind-config.yaml --name kind

# 2. Vendor chart dependencies
(cd charts/app && helm dependency build)

# 3. Start Dev Loop (Fat images + Hot Reload)
tilt up
```

Tilt exposes everything automatically:

- **Tilt HUD:** [http://localhost:10350](http://localhost:10350)
- **Backend:** [http://localhost:8000/docs](http://localhost:8000/docs)
- **Frontend:** [http://localhost:3000](http://localhost:3000)

**Tilt uses:**
`charts/app/values.local.dev.yaml` → dev images, NodePorts, hot reload.

## 🔄 The 5-Stage Lifecycle (4 Loops + 1 Verify)

JetScale operates on **four distinct feedback loops** and one final verification stage. Each stage increases in fidelity and reduces speed.

| Stage | Loop Name | Tooling | Environment | Purpose |
| :-- | :-- | :-- | :-- | :-- |
| **1** | **Inner Loop** | Tilt | Kind (Local) | **Speed.** Hot reload, fat images, debuggers attached. |
| **2** | **Outer Loop** | Skaffold | Kind (Local) | **Parity.** Builds real Alpine images locally. Tests "prod-like" runtime. |
| **3** | **CI Loop** | Skaffold | Kind (CI Runner) | **Gating.** Uses official CI artifacts. Ensures clean build context. |
| **4** | **Preview Loop** | Skaffold | EKS (Ephemeral) | **Integration.** Deploys to `pr-123.app.jetscale.ai`. Tests AWS dependencies. |
| **5** | **Live Verify** | Mage | EKS (Prod) | **Trust.** Non-destructive smoke tests against the live endpoint. |

**Key Architecture Note:**
- **Tilt** never runs Skaffold.
- **Skaffold** never touches dev-mode images.
This separation prevents config drift and ensures Stage 2 and Stage 3 are mathematically identical.

## 🧙‍♂️ Mage Tasks

We use Mage to orchestrate these loops.

### Install Mage

```bash
go install github.com/magefile/mage@latest
```

### Lifecycle Commands

```bash
# STAGE 1: Inner Loop
mage dev               # tilt up

# STAGE 2: Outer Loop (Local Parity)
mage test:locale2e     # Builds local Alpine images -> Kind

# STAGE 3: CI Loop (Gating)
mage test:ci           # Deploys CI artifacts -> Kind

# STAGE 4: Preview Loop (Integration)
mage test:preview      # Deploys to EKS Namespace

# STAGE 5: Live Verify (Trust)
mage test:live         # Smoke tests app.jetscale.ai
```

### Utilities

```bash
mage clean             # tear down tilt + local resources
```

## 📂 Repository Layout

- `Tiltfile` — Stage 1 Orchestrator
- `skaffold.yaml` — Stage 2-5 Orchestrator
- `charts/app` — Umbrella Helm chart
- `kind/` — Cluster config
- `charts/app/values.*.yaml` — Environment configs:

  | File | Stage | Purpose |
  | -- | -- | -- |
  | `values.local.dev.yaml` | 1 | Tilt dev mode (dev images + hot reload) |
  | `values.local.e2e.yaml` | 2, 3 | Alpine images (ClusterIP) |
  | `values.preview.yaml` | 4 | Preview (EKS ephemeral namespaces) |
  | `values.live.yaml` | 5 | Live environment (EKS) |

## ⚡ Preview Environments

Preview environments are **runtime slices of EKS**, not folders.

- `values.preview.yaml` defines the template.
- CI passes runtime inputs (`PR_NUMBER`, `GIT_SHA`).
- Helm deploys into isolated namespaces like `jetscale-pr-123`.
- They are cleaned up automatically when the PR closes.

## ✅ Current Guarantees

- **Local Dev = Tilt + dev images** (fast, reload)
- **Local E2E = Skaffold + Kind + Alpine images** (live-parity)
- **Docker images auto-start uvicorn** by default
- **Charts remain clean** and environment-specific
- **Tests run exactly as they will in CI**
