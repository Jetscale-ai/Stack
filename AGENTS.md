# The JetScale Stack Constitution

## 0. The 5-Repo Topology (Global Context)

We operate under the **Fractal Franchise Model**. This repository is one part of a distributed system:

| Repo | Role | Artifact | Responsibility |
| :--- | :--- | :--- | :--- |
| **`iac`** | **The Soil** | `.tfstate` | Provisions Cluster, IAM, S3, and **bootstraps ArgoCD**. |
| **`stack`** | **The App** | OCI Chart | Builds the Business Logic (`backend` + `frontend` umbrella). |
| **`observability`** | **The Tools** | OCI Chart | Builds the Platform Layer (Loki, Grafana, Promtail). |
| **`catalog`** | **The Pattern** | Helm Charts | Defines **Blueprints** (Argo AppSets) for *how* things are installed. |
| **`fleet`** | **The State** | Live Cluster | Defines **Instances**. Pins versions and connects Infra to Apps. |

**Related Documentation:**

- Infrastructure provisioning: `../iac/README.md` (The Soil)
- Deployment state management: `../fleet/README.md` (Instances)
- Blueprint patterns: `../catalog/README.md` (Patterns)
- Source services: `../backend/README.md`, `../frontend/README.md`
- Observability artifacts: `../observability/README.md`

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

- **Validation First:** No configuration shall be committed without passing `mage validate:envs aws`. This ensures `envs/` configurations always align with `charts/` schemas.
- **Environment Parity:** The `charts/jetscale` definition is universal. Environments (`envs/`) differ only in configuration (values), never in structure (templates).

### 3.3. Public by Default (Ethos)

- This repo is public. No secrets (API keys, passwords) shall ever be committed. Secrets are injected via External Secrets Operator or local `.env` overrides (gitignored).

### 3.4. The Sovereign Boundary (Autonomy)

****

- **Chart Agnosticism:** The Helm chart must remain "Platform Agnostic." It declares *intent* (e.g., standard `Ingress` resources, `ExternalSecret` references), never *implementation* *e.g*, AWS ALB creation logic, Route53 update*).*
- **Infrastructure Responsibility:** The Infrastructure layer (Terraform/OpenTofu) is responsible for installing the "Drivers" that fulfill the Chart's intent. The Chart does not care *how* the Ingress is fulfilled, only that it *is*.
- **The "Client Rule":** We never force a client to perform manual infrastructure work to install our App. The Chart is a self-contained deployable unit.
- **Multi-Cloud Portability:**
  - **AWS (SaaS):** Infra installs **AWS LB Controller** + **ExternalDNS**. The Chart's `Ingress*bec*mes an ALB.
  - **Azure (AKS):** Infra installs **AGIC** (App Gateway Ingress Controll*r) o* **Nginx**. The *same* Chart's `Ingress` becomes an Azure App Gateway.
  - **OpenStack/On-Prem:** Infra installs **Octavia** or **MetalLB**. The *same* Chart's `Ingress` becomes a LoadBalancer IP.

### The Artifact Boundary

We produce an **Immutable OCI Artifact**.

- We do **not** manage environment-specific values (replicas, domains) in this repo. Those belong in `../fleet`.
- We do **not** manage infrastructure dependencies (RDS, S3). Those belong in `../iac`.

## 4. The Eudaimonia Framework

All architectural decisions must be justified by the 12 Invariants:
*Ethos (Identity), Logos (Reason), Praxis (Action).*

## 5. Operational Details

**Local development:**

- gh cli local access
- gh act cli locally installed
- aws cli installed; except when the human needs to use the breakglass mechanism, in which case instruct the human with commands to run
- git commits require -S gpg signature by a human, so you may not commit; never push unless asked explicitly

- you may propose git commit messages in the style of past commits, but never commit yourself. Aim for `git commit -F - <<'EOF'...` style multiline commit messages

**Chart maintenance:**

- Chart upversion protocol: @agents/upversion.md

## 6. Ephemeral Environments: No-Loop Playbook

This section exists because we lost time to “paper cuts” that looked like infra bugs but were actually:
OIDC subject mismatch, missing ALB TLS annotations, green-but-dead workflows, and Terraform destroy vs missing clusters.

- Architecture doc: `docs/ephemeral-architecture.md`

### 6.1. Parity Rule (Preview ↔ Live)

- **Rule:** Preview + Live must match for DNS/TLS semantics via the `envs/` inheritance model:
  - Shared ALB behavior lives in `envs/aws.yaml`
  - Wildcard cert ARN must be consistent between `envs/preview/preview.yaml` and `envs/live/console.yaml`
  - `alb.ingress.kubernetes.io/listen-ports` includes 80+443
  - `alb.ingress.kubernetes.io/ssl-redirect: "443"`
  - `alb.ingress.kubernetes.io/certificate-arn` points at the wildcard cert
  - `alb.ingress.kubernetes.io/ssl-policy` pinned
- **Why:** otherwise ephemeral environments can be HTTP-only while users/workflows assume HTTPS.

### 6.2. "Green Must Mean Reachable"

- **Rule:** The ephemeral workflow must fail if `https://<public_host>/` never becomes reachable.
- **Protocol:** `Verify Health` must be a hard gate (and dump diagnostics on failure).

### 6.3. OIDC Trust: Janitor Must Use per-PR Environment

- **Symptom:** `Not authorized to perform sts:AssumeRoleWithWebIdentity` on PR close cleanup.
- **Root cause:** Live trust policy expects `sub=repo:Jetscale-ai/Stack:environment:pr-*`.
- **Protocol:** cleanup workflows must set:
  - `environment.name: pr-${{ github.event.number }}`

### 6.4. Destroy Semantics: Terraform vs Fallback Cleanup

- **Terraform destroy** can fail if the cluster is missing/unreachable because it still needs to refresh/destroy in-cluster resources.
- **Protocol:** if the EKS cluster is already gone, skip TF destroy and go straight to the AWS cleanup script.

### 6.5. Cleanup Tag Truths

- **Jetscale app infra** uses `jetscale.env_id=<env_id>`.
- **AWS LB Controller** uses `elbv2.k8s.aws/cluster=<env_id>` for ELBv2 artifacts.
- **Protocol:** cleanup must delete ELBv2 load balancers + target groups using the `elbv2.k8s.aws/cluster` tag.

### 6.6. Breakglass Diagnosis (Read-only)

**No manual changes.** Diagnose with read-only checks, then fix via repo changes.

```bash
export AWS_PAGER=""
export PAGER=cat
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

HOST="pr-7-<slug>.jetscale.ai"
dig +short "$HOST" A
curl -sSIk --max-time 8 "https://${HOST}/" | head -n 20
```

If ALB name is too long for `describe-load-balancers --names`, look up by DNSName:

```bash
ALB_HOST="k8s-...us-east-1.elb.amazonaws.com"
LB_ARN="$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${ALB_HOST}'].LoadBalancerArn | [0]" \
  --output text)"
aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN"
```
