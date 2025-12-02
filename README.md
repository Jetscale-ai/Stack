# JetScale Stack

The central infrastructure, deployment, and orchestration repository for the JetScale Platform.

## 🚀 The Vision

We run JetScale on a **"Platform-First"** model.  
Instead of a drifting `docker-compose`, this repo enables **Live-like environments locally** via:

- **Tilt** → Local Dev (hot reload, dev images)
- **Skaffold + Kind** → Local E2E (Alpine runtime parity)
- **Helm + OCI** → Immutable, versioned deployment artifacts

This produces a consistent experience across Dev → CI → Preview → Live.

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

Tilt exposes everything automatically:

- **Tilt HUD:** [http://localhost:10350](http://localhost:10350)
- **Backend:** [http://localhost:8000/docs](http://localhost:8000/docs)
- **Frontend:** [http://localhost:3000](http://localhost:3000)

## 📂 Repository Layout

We adhere to a strict **Definition vs. Instantiation** split:

- `charts/app` — **The Definition.** The generic "Umbrella Chart". Dependencies are pinned to immutable OCI versions.
- `envs/` — **The Instantiation.** Environment-specific configurations.
  - `envs/live/values.yaml` → Production (HA, replication).
  - `envs/preview/values.yaml` → CI/Preview (Ephemeral).
- `values.local.*.yaml` — Local overrides (kept near chart for Tilt/Skaffold convenience).

## 🔗 Modifying Subcharts ("Link Mode")

By default, the Stack uses immutable OCI charts (`oci://ghcr.io/...`). To modify the underlying `backend` or `frontend` templates:

1.  **Edit `charts/app/Chart.yaml`**:
    ```yaml
    dependencies:
      - name: backend-api
        # repository: "oci://ghcr.io/jetscale-ai/charts"  <-- Comment this
        repository: "file://../../../backend/charts"        <-- Uncomment this
    ```
2.  **Update Dependencies**: `helm dependency update charts/app`
3.  **Dev Loop**: `tilt up` (Changes to templates now take effect).
4.  **Revert**: Do not commit `file://` paths to main.

## 🔄 The 5-Stage Lifecycle

| Stage | Loop Name | Tooling | Environment | Purpose |
| :-- | :-- | :-- | :-- | :-- |
| **1** | **Inner Loop** | Tilt | Kind (Local) | **Speed.** Hot reload, fat images. |
| **2** | **Outer Loop** | Skaffold | Kind (Local) | **Parity.** Builds local code -> Alpine images. |
| **3** | **CI Loop** | Skaffold | Kind (CI Runner) | **Gating.** Deploys remote OCI artifacts. |
| **4** | **Preview Loop** | Skaffold | EKS (Ephemeral) | **Integration.** `pr-123.app.jetscale.ai`. |
| **5** | **Live Verify** | Mage | EKS (Prod) | **Trust.** Non-destructive smoke tests. |

## 🧙‍♂️ Mage Tasks

```bash
mage validate:envs     # Check structural integrity of all envs/
mage test:locale2e     # Run Stage 2 (Local Parity)
mage test:ci           # Run Stage 3 (CI Mode)
```
