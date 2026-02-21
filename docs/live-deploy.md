# ✅ Justified Action: Helm-first Live Deployment Contract

**Goal:** Establish a single, deterministic "Helm-only" deployment path for Live (console.jetscale.ai) aligned with the future ArgoCD GitOps flow, and preserving parity with preview envs

**Justification (Eudaimonia Invariants):**

- Prudence: reduce accidental prod deploy paths and namespace drift
- Clarity: one blessed command + explicit prerequisites
- Concord: Terraform owns cluster "pipes"; Helm owns app "intent"
- Identity: live deploys must target the correct namespace and secret contract

**Audit:** This document does not introduce credentials; it only documents required secret shapes

## Live deploy (console.jetscale.ai) — Helm-only

## CI/CD behavior (Option B: Decoupled Deploy)

This repo separates the **Artifact Lifecycle** (published chart versions) from the **Deployment Lifecycle**
(environment values):

- **Chart changes (`charts/**`)**: Stage 6 will publish a new chart version (semantic-release) and deploy that new version.
- **Prod config changes (`envs/prod/**`)**: Stage 6 will **skip version inflation** and redeploy the **latest tagged version**
  with the updated prod values (see `envs/aws.yaml`, `envs/prod/default.yaml`, `envs/prod/console.yaml`).

### Preconditions (Terraform-owned "pipes")

- **Namespace**: `jetscale-console` (convention: `{client_name}-{project}`); Helm `--create-namespace` can create it.
- **External Secrets Operator** installed in the cluster (Terraform `clients/` stack).
- **IaC** creates RDS and admin secret at `jetscale-prod/database/admin`. **Stack** (Helm) creates SecretStore, db-bootstrap Job (per-project DB + `jetscale-prod/database/console`), and ExternalSecrets that materialize:
  - `jetscale-console-db-secret` (from `jetscale-prod/database/console`, created by db-bootstrap)
  - `jetscale-console-redis-secret`
  - `jetscale-console-common-secrets`

### Preconditions (out-of-band "vault values")

This repo uses **Option B (Container/Value Split)** for sensitive credentials:

- **Terraform** creates the **secret container** and grants ESO access (IRSA policy).
- **Humans/automation** inject the **secret value** out-of-band (rotation-safe; SOC2-friendly).

Database credentials are **not** out-of-band: the Stack db-bootstrap Job creates the per-project DB and writes credentials to `jetscale-prod/database/{project}`. Only the AWS client secret is out-of-band; it must exist **and** have a value:

- Name: `jetscale-prod/application/aws/client` (cluster prefix, not release name)
- Keys required:
  - `JETSCALE_CLIENT_AWS_REGION`
  - `JETSCALE_CLIENT_AWS_ROLE_ARN`
  - `JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID`

See `iac/clients/README.md` for copy/paste commands to create/update it.

### Deploy command (Helm)

From the `stack/` directory:

```bash
# Ensure chart dependencies are present (pulls pinned OCI subcharts)
helm dependency build charts/jetscale

# Deploy/upgrade Live into the Terraform-managed namespace
helm upgrade --install jetscale-console charts/jetscale \
  --namespace jetscale-console \
  --create-namespace \
  --values envs/aws.yaml \
  --values envs/prod/default.yaml \
  --values envs/prod/console.yaml
```

### Quick verification

```bash
# Verify the secret exists (created by ESO)
kubectl -n jetscale-console get secret jetscale-aws-client-secret

# Verify backend pods are not blocked by missing secrets
kubectl -n jetscale-console get pods
kubectl -n jetscale-console describe pod -l app.kubernetes.io/name=backend | sed -n '1,160p'
```
