# JetScale Stack

The central infrastructure, deployment, and orchestration repository for the JetScale Platform.

## 🚀 The Vision

We are moving to a **"Platform-First"** development model. Instead of maintaining disparate `docker-compose` files that drift from live deployments, we use this repository to spin up a **Live-Like** environment on your laptop using **Tilt** and **Kind**.

## 🛠️ Quick Start (Local Dev)

### Prerequisites

1. **Docker** (Desktop or Engine)

2. **Kind**: `go install sigs.k8s.io/kind@latest`

3. **Tilt**: `curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash`

4. **Helm**: `brew install helm`

### Boot the Stack

1. Clone this repo alongside your service repos:

   ```text

   /code

     /backend

     /frontend

     /stack  <-- You are here

   ```

2. Run the platform:

   ```bash

   tilt up

   ```

   _Hit `Space` to open the HUD. You will see your Backend and Frontend services spinning up, connected to a real Postgres/Redis._

3. **Development:**

   - Edit files in `../backend` or `../frontend`.

   - **Tilt** detects the change and syncs it into the running container instantly.

   - The backend server auto-reloads (just like `docker-compose`).

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

### Environment Profiles

- **`local-kind`**: Laptop Kind cluster with hot reload for inner-loop dev
- **`ci-kind`**: Ephemeral Kind cluster for CI/CD testing
- **`preview`**: Ephemeral EKS namespace per PR (e.g., `pr-123.app.jetscale.ai`)
- **`live`**: Live EKS deployment with HA configuration

## ⚡️ Preview Environments = Runtime State

Preview environments are **not** folders checked into this repo—they are runtime slices
of the already-provisioned EKS cluster. Each preview is created by combining:

1. **Base config** — `charts/app/values.preview.yaml` describes the lightweight shape
   (single replica, no persistence).
2. **Runtime inputs** — CI passes dynamic values such as `PR_NUMBER`, `GIT_SHA`, and
   ingress host overrides to Helm/Skaffold.
3. **Isolation** — Mage generates unique Kubernetes namespaces (`jetscale-pr-123`) so
   every PR stays sandboxed.

Flow example:

1. PR #101 opens and triggers `mage test:preview`.
2. Mage detects `PR_NUMBER=101`, derives namespace `jetscale-pr-101` and host
   `pr-101.app.jetscale.ai`.
3. Skaffold deploys with `-p preview --namespace jetscale-pr-101
   --set ingress.host=pr-101.app.jetscale.ai`.
4. Tests hit `https://pr-101.app.jetscale.ai`.
5. When the PR merges/closes, CI uninstalls that release to clean up.

## 🧙‍♂️ Developer Tasks (Mage)

We use [Mage](https://magefile.org/) for task orchestration.

1. **Install Mage** (if you haven't already):

   ```bash
   go install github.com/magefile/mage@latest
   ```

2. **Available Tasks:**

   ```bash
   # Start local development environment
   mage dev

   # Clean up local environment
   mage clean

   # Run CI pipeline locally
   mage ci

   # Run tests
   mage test:local     # Kind + local images
   mage test:ci        # Kind + CI artifacts
   mage test:preview   # Ephemeral EKS namespace
   mage test:live      # Live verification (no deploy)

   # Deploy to environment
   mage deploy preview
   mage deploy live
   ```

3. **List all available tasks:**

   ```bash
   mage -l
   ```

## 🧪 E2E Target Matrix

| Mage Command        | Skaffold Profile | Cluster | Purpose                                   | Behavior |
| :------------------ | :--------------- | :------ | :---------------------------------------- | :------- |
| `mage test:local`   | `local-kind`     | Kind    | Contract tests with laptop-built images   | Builds locally and loads into Kind |
| `mage test:ci`      | `ci-kind`        | Kind    | CI gating before previews                 | Uses CI-tagged artifacts, ClusterIP services |
| `mage test:preview` | `preview`        | EKS     | Pre-merge fidelity with ephemeral ingress | Deploys to PR namespace, tears down afterward |
| `mage test:live`    | _(verification)_ | EKS     | Post-deploy smoke verification            | No deploys; hits `app.jetscale.ai` in smoke mode |

> `mage test:live` is intentionally non-destructive—it only verifies the already deployed live stack.

## 🚢 Deployment Profiles

### Preview Environment (PR-based)

Preview environments are automatically created for each PR:

```bash
# Deploy preview environment (typically done by CI)
skaffold run -p preview --set ingress.host=pr-123.app.jetscale.ai
```

**Characteristics:**

- Ephemeral EKS namespace per PR
- No persistent storage (faster provisioning, lower cost)
- Single replica for cost efficiency
- Accessible via PR-specific subdomain

### Live Environment

Live deployments use high-availability configuration:

```bash
# Deploy to the live environment (typically done by CI/CD pipeline)
skaffold run -p live
```

**Characteristics:**

- High availability (3+ replicas)
- Persistent storage with replication
- Resource limits and requests configured
- Live-grade ingress with SSL certificates
