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

## 🔄 Development Workflow

- **Backend:** Edit `../backend`, auto-reload via `uvicorn --reload`
- **Frontend:** Edit `../frontend`, Tilt rebuilds + redeploys
- **DB/Redis:** Managed via Helm dependencies in the umbrella chart

The dev loop stays fast and isolated. No Skaffold or Alpine images here.

## 📂 Repository Layout

- `Tiltfile` — Local Dev Orchestrator (inner loop)
- `skaffold.yaml` — E2E/CI orchestrator (outer loop)
- `charts/app` — Umbrella Helm chart
- `kind/` — Cluster config
- `charts/app/values.*.yaml` — Environment configs:

  | File | Purpose |
  | -- | |
  | `values.local.dev.yaml` | Tilt dev mode (dev images + hot reload) |
  | `values.local.e2e.yaml` | Local E2E Alpine images (ClusterIP) |
  | `values.preview.yaml` | Preview (EKS ephemeral namespaces) |
  | `values.live.yaml` | Live environment (EKS) |

## 🔄 Two-Loop Local Architecture

JetScale now uses **two distinct local loops**, each backed by Helm values:

| Loop | Tooling | Values File | Images Used | Purpose |
| - | | -- | | - |
| **Inner Loop** | Tilt | `values.local.dev.yaml` | `*-dev` fat images | Hot reload, live-like local dev |
| **Outer Loop (Local)** | Skaffold + Kind | `values.local.e2e.yaml` | Alpine runtime images | Live-parity smoke/E2E tests |

**Tilt does not run Skaffold**, and **Skaffold does not touch dev-mode images**.
This prevents config drift and avoids NodePort collisions.

## 🧙‍♂️ Mage Tasks

We use Mage for all developer commands.

### Install Mage

```bash
go install github.com/magefile/mage@latest
```

### Available Dev/Test Tasks

```bash
mage dev               # tilt up (inner loop)
mage clean             # tear down tilt + local resources

mage test:localdev    # smoke test against running Tilt env
mage test:locale2e     # full Alpine E2E via skaffold + kind (outer loop)

mage test:ci           # CI-kind test using CI-built artifacts
mage test:live         # hit live for verification only
```

## 🧪 E2E Target Matrix (Updated)

| Mage Command | Skaffold Profile | Cluster | Purpose | Behavior |
| | - | - | - | -- |
| `mage test:local-dev` | _(none)_ | Kind | Quick smoke test against Tilt env | Hits `localhost:8000` directly |
| `mage test:locale2e` | `local-kind` | Kind | Live-parity E2E with local Alpine images | Builds local images, loads into Kind, ClusterIP + port-forward |
| `mage test:ci` | `ci-kind` | Kind | CI-gating tests using CI images | No local builds |
| `mage test:preview` | `preview` | EKS | PR ephemeral namespace testing | Deploy isolated namespace |
| `mage test:live` | _(verification)_ | EKS | Smoke tests against `app.jetscale.ai` | **No deploy** |

## ⚡ Preview Environments

Preview environments are **runtime slices of EKS**, not folders.

- `values.preview.yaml` defines the template
- CI passes runtime inputs (`PR_NUMBER`, `GIT_SHA`)
- Helm deploys into isolated namespaces like:

```txt
jetscale-pr-123
```

They are cleaned up automatically when the PR closes.

## ✅ Current Guarantees

- **Local Dev = Tilt + dev images** (fast, reload)
- **Local E2E = Skaffold + Kind + Alpine images** (live-parity)
- **Docker images auto-start uvicorn** by default
- **Charts remain clean** and environment-specific
- **Tests run exactly as they will in CI**
