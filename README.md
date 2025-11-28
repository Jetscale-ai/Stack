# JetScale Stack

The central infrastructure, deployment, and orchestration repository for the JetScale Platform.

## 🚀 The Vision

We are moving to a **"Platform-First"** development model. Instead of maintaining disparate `docker-compose` files that drift from live deployments, we use this repository to spin up a **Live-Like** environment on your laptop using **Tilt** and **Kind**.

## 🛠️ Quick Start (Local Dev)

### 1. Prerequisites

- **Docker** (Desktop or Engine)
- **Kind**: `go install sigs.k8s.io/kind@latest`
- **Tilt**: `curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash`
- **Helm**: `brew install helm`

### 2. Boot the Platform

Run these commands from the `stack/` directory:

```bash
# 1. Provision Infrastructure (Custom Ports for localhost access)
kind create cluster --config kind/kind-config.yaml --name kind

# 2. Vendor Dependencies (First Run Only)
(cd charts/app && helm dependency build)

# 3. Ignite
tilt up
```

_Hit `Space` to open the HUD. You will see your Backend and Frontend services spinning up, connected to a real Postgres/Redis._

### 3. Access

- **Tilt HUD:** [http://localhost:10350](http://localhost:10350)
- **Frontend:** [http://localhost:3000](http://localhost:3000) (No manual port-forward needed)
- **Backend API:** [http://localhost:8000/docs](http://localhost:8000/docs)

## 🔄 Development Workflow

- **Backend:** Edit files in `../backend`. Tilt syncs them instantly. `uvicorn` auto-reloads.
- **Frontend:** Edit files in `../frontend`. Tilt rebuilds the image and redeploys (approx 10-20s).

## 📂 Repository Layout

- `Tiltfile`: The orchestrator that replaces `docker-compose.yml`.
- `charts/app`: The Umbrella Helm Chart (The "Installer").
- `kind/`: Local cluster configuration.
- `charts/app/values.*.yaml`: Environment-specific configurations:
  - `values.local.yaml`: Local development (Kind)
  - `values.preview.yaml`: Preview environments (Ephemeral EKS)
  - `values.live.yaml`: Live environment (EKS)

## 🔄 Three-Loop Architecture

We follow a **Three-Loop** development model:

| Loop           | Environment | Cluster | Purpose                                 |
| :------------- | :---------- | :------ | :-------------------------------------- |
| **Inner Loop** | Local Dev   | Kind    | Developer workstation with hot-reload   |
| **Outer Loop** | CI          | Kind    | Automated testing in ephemeral clusters |
| **Preview**    | Preview     | EKS     | PR-based ephemeral namespaces           |
| **Live**       | Live        | EKS     | High-availability deployment             |

## ⚡️ Preview Environments = Runtime State

Preview environments are **not** folders checked into this repo—they are runtime slices of the already-provisioned EKS cluster.

1. **Base config** — `charts/app/values.preview.yaml` describes the lightweight shape (single replica, no persistence).
2. **Runtime inputs** — CI passes dynamic values such as `PR_NUMBER` and `GIT_SHA`.
3. **Isolation** — Unique Kubernetes namespaces (`jetscale-pr-123`) keep work sandboxed.

## 🧙‍♂️ Developer Tasks (Mage)

We use [Mage](https://magefile.org/) for task orchestration.

1. **Install Mage**: `go install github.com/magefile/mage@latest`

2. **Available Tasks:**

   ```bash
   # Start local development environment (Wraps 'tilt up')
   mage dev

   # Clean up local environment
   mage clean

   # Run CI pipeline locally
   mage ci

   # Run tests
   mage test:local     # Kind + local images
   mage test:ci        # Kind + CI artifacts
   mage test:live      # Live verification (no deploy)
   ```

## 🧪 E2E Target Matrix

| Mage Command        | Skaffold Profile | Cluster | Purpose                                   | Behavior |
| :------------------ | :--------------- | :------ | :---------------------------------------- | :------- |
| `mage test:local`   | `local-kind`     | Kind    | Contract tests with laptop-built images   | Builds locally and loads into Kind |
| `mage test:ci`      | `ci-kind`        | Kind    | CI gating before previews                 | Uses CI-tagged artifacts, ClusterIP services |
| `mage test:preview` | `preview`        | EKS     | Pre-merge fidelity with ephemeral ingress | Deploys to PR namespace, tears down afterward |
| `mage test:live`    | _(verification)_ | EKS     | Post-deploy smoke verification            | No deploys; hits `app.jetscale.ai` in smoke mode |
