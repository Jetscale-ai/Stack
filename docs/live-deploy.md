## ✅ Justified Action: Helm-first Live Deployment Contract
#
# Goal: Establish a single, deterministic “Helm-only” deployment path for Live (console.jetscale.ai),
#       aligned with the future ArgoCD GitOps flow, and preserving parity with preview envs.
#
# Justification (Eudaimonia Invariants):
# - Prudence: reduce accidental prod deploy paths and namespace drift.
# - Clarity: one blessed command + explicit prerequisites.
# - Concord: Terraform owns cluster “pipes”; Helm owns app “intent”.
# - Identity: live deploys must target the correct namespace and secret contract.
#
# Audit: This document does not introduce credentials; it only documents required secret shapes.

## Live deploy (console.jetscale.ai) — Helm-only

## CI/CD behavior (Option B: Decoupled Deploy)

This repo separates the **Artifact Lifecycle** (published chart versions) from the **Deployment Lifecycle**
(environment values):

- **Chart changes (`charts/**`)**: Stage 6 will publish a new chart version (semantic-release) and deploy that new version.
- **Live config changes (`envs/live/**`)**: Stage 6 will **skip version inflation** and redeploy the **latest tagged version**
  with the updated `envs/live/values.yaml`.

### Preconditions (Terraform-owned “pipes”)

- **Namespace**: `jetscale-prod` (convention: `{client_name}-{env}`)
- **External Secrets Operator** installed in the cluster (Terraform `clients/` stack).
- **SecretStore** in namespace `jetscale-prod` created by Terraform.
- **ExternalSecret manifests** created by Terraform that materialize:
  - `jetscale-db-secret`
  - `jetscale-redis-secret`
  - `jetscale-common-secrets`
  - `jetscale-aws-client-secret`

### Preconditions (out-of-band “vault values”)

This repo uses **Option B (Container/Value Split)** for sensitive credentials:

- **Terraform** creates the **secret container** and grants ESO access (IRSA policy).
- **Humans/automation** inject the **secret value** out-of-band (rotation-safe; SOC2-friendly).

The AWS Secrets Manager secret backing the AWS client ExternalSecret must exist **and** have a value:

- Name: `jetscale-prod/application/aws/client`
- Keys required:
  - `JETSCALE_CLIENT_AWS_REGION`
  - `JETSCALE_CLIENT_AWS_ROLE_ARN`
  - `JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID`

See `iac/clients/README.md` for copy/paste commands to create/update it.

### Deploy command (Helm)

From the `stack/` directory:

```bash
# Ensure chart dependencies are present (pulls pinned OCI subcharts)
helm dependency build charts/app

# Deploy/upgrade Live into the Terraform-managed namespace
helm upgrade --install jetscale-stack charts/app \
  --namespace jetscale-prod \
  --create-namespace \
  --values envs/live/values.yaml
```

### Quick verification

```bash
# Verify the secret exists (created by ESO)
kubectl -n jetscale-prod get secret jetscale-aws-client-secret

# Verify backend pods are not blocked by missing secrets
kubectl -n jetscale-prod get pods
kubectl -n jetscale-prod describe pod -l app.kubernetes.io/name=backend | sed -n '1,160p'
```


