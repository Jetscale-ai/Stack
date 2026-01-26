# Ephemeral environments architecture (Cluster-per-PR)

This document explains how the **Ephemeral Cluster per PR** workflow converges on a working environment, why it’s structured as a multi-stage loop, and what the **secret contract** is between Terraform (infra) and Helm (app).

## Goals

- **Green must mean reachable**: a “successful” run must result in a reachable `https://<public_host>/`.
- **Convergence over perfection**: reruns should adopt/repair existing resources instead of failing or forcing manual cleanup.
- **Single source of truth for deployment**: application install/upgrade is centralized in `scripts/gha/ephemeral/deploy_stack.sh`.

## Key identities (naming)

- **ENV_ID**: `pr-<number>` (e.g., `pr-123`)
- **Cluster name**: `${ENV_ID}`
- **Namespace**: `${ENV_ID}`
- **Helm release**: `${ENV_ID}`
- **Public host**: `${ENV_ID}-<branch-slug>-unstable.jetscale.ai`

## Values contract (how Helm values are composed)

The ephemeral deploy composes values in strict precedence order:

1. `envs/aws.yaml` (cloud defaults, ALB/DNS/TLS behavior)
2. `envs/preview/preview.yaml` (preview defaults, including suspended CronJobs)
3. Generated runtime overrides (host + tenant + envFrom + registry secret wiring)

The runtime overrides exist because some chart values (like `ingress.hosts`) are keyed maps that cannot be safely “rewired” via `--set`.

## The convergence loop (Day 0 vs Day 2)

Ephemeral environments are not a single “create and forget” action. They converge via repeated runs.

```text
PR labeled "preview" (or workflow_dispatch)
  |
  v
Identity + Hostname  ---> ENV_ID, PUBLIC_HOST
  |
  v
Integrity: Zombie State Prune
  |
  v
Integrity: State Reconciliation (adopt orphans, unblock webhooks, import known resources)
  |
  v
Terraform Apply (with retries for known transient failures)
  |
  v
Preflight (ESO ready + secret contract satisfied + registry pull secret exists)
  |
  v
Helm Deploy (deploy_stack.sh)
  |
  v
Verify Health (hard gate)
```

## Day 0 (bootstrap)

Common scenario: the **Terraform state is missing** or the **cluster doesn’t exist yet**.

- Terraform applies are staged so AWS-only resources can come up first (e.g., VPC/NAT, EKS control plane).
- Kubeconfig-dependent providers are only exercised after the cluster exists.

## Day 2 (rerun / repair)

Common scenario: resources exist in AWS, but Terraform state is partially missing or the previous run ended mid-flight.

- State reconciliation attempts to **import/adopt** known resources.
- Terraform apply retries handle:
  - **State lock contention** (force-unlock once, then retry)
  - **AWS Load Balancer Controller webhook delays** (wait for controller, then retry)

## The secret contract (Container vs Value)

Ephemeral environments follow the **Container/Value split**:

- **Terraform (IaC) owns containers and access**:
  - installs **External Secrets Operator (ESO)**
  - creates SecretStores / IAM roles / policies so ESO can read Secrets Manager
- **Humans/automation own values**:
  - inject the actual secret JSON into AWS Secrets Manager
  - ESO materializes Kubernetes secrets from those values

## Ephemeral AWS client secret (Secrets Manager)

- **Secret ID**: `${ENV_ID}-ephemeral/application/aws/client`
- **Required keys**:
  - `JETSCALE_CLIENT_AWS_REGION`
  - `JETSCALE_CLIENT_AWS_ROLE_ARN`
  - `JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID`

`scripts/gha/ephemeral/preflight.sh` invokes `scripts/gha/ephemeral/ensure_secrets.sh` to ensure the secret exists and ESO has created the corresponding Kubernetes Secret.

## Kubernetes secrets expected by the Helm chart

The backend charts expect secret/configmap refs that are **release-prefixed**:

- `<release>-db-secret`
- `<release>-redis-secret`
- `<release>-common-secrets`
- `<release>-aws-client-secret`

There is also a required (sometimes placeholder) secret:

- `<release>-app-secrets` (created/ensured by `deploy_stack.sh`)

## Operational scripts (where the logic lives)

- Workflow: `.github/workflows/env-ephemeral.yaml`
- Terraform + adoption:
  - `scripts/gha/ephemeral/state_reconcile.sh`
  - `scripts/gha/ephemeral/terraform_apply.sh`
  - Shared retry logic: `scripts/lib/tf_helpers.sh`
- Preconditions:
  - `scripts/gha/ephemeral/preflight.sh`
  - `scripts/gha/ephemeral/ensure_secrets.sh`
- App deploy:
  - `scripts/gha/ephemeral/deploy_stack.sh`
  - Shared values ordering: `scripts/lib/helm_helpers.sh`
