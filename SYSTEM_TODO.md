# System Settings - Helm Chart & Deployment Plan

## Overview

This document covers the deployment considerations for System Settings across multiple JetScale stacks in a shared EKS cluster.

## Current Status: ✅ READY FOR DEPLOYMENT

System Settings is fully implemented in backend and frontend. The Helm chart needs minimal updates to support the reduced env var footprint.

## Architecture

```text
Resolution order: DB > ENV > Default

┌─────────────────────────────────────────────────────────────┐
│  DB (admin UI)     - HIGHEST PRIORITY                       │
│  Per-stack settings, configured via System Settings UI      │
├─────────────────────────────────────────────────────────────┤
│  ENV (Helm/K8s)    - FALLBACK (Org Defaults)                │
│  Set at deploy time, used when no DB value exists           │
│  Good for org-wide defaults across all stacks               │
├─────────────────────────────────────────────────────────────┤
│  Default (code)    - LAST RESORT                            │
│  Sensible defaults baked into application                   │
└─────────────────────────────────────────────────────────────┘
```

**Key behaviors:**

- DB values (set via admin UI) **always win** over ENV vars
- ENV vars serve as **org-wide defaults** that clients can override via UI
- Resetting a DB value **falls back to ENV** (if set) or Default

## Why This Precedence?

| Approach | Precedence | Use Case |
|----------|------------|----------|
| **12-Factor** | ENV > Default | Single-tenant, ops-controlled |
| **SaaS/Multi-tenant** | DB > ENV > Default | Per-stack customization via UI |

We use the **SaaS model** because:

1. **Per-stack customization**: Each client stack can have different settings via admin UI
2. **Org-wide defaults**: ENV vars provide fallback defaults across all stacks
3. **Zero-redeploy changes**: Admins can change settings without touching infrastructure
4. **Client self-service**: Clients can configure their own API keys, SMTP, etc.

## Env Vars Classification

### Must Stay in Helm values.yaml (Infrastructure)

| Env Var | Reason | Secret Type |
|---------|--------|-------------|
| `JETSCALE_APP_NAME` | Deployment identity | - |
| `JETSCALE_VERSION` | Build artifact | - |
| `JETSCALE_DEBUG` | Infra debugging | - |
| `JETSCALE_HOST` | Network binding | - |
| `JETSCALE_PORT` | Network binding | - |
| `JETSCALE_ALLOWED_ORIGINS` | CORS security | - |
| `JETSCALE_LOG_LEVEL` | Infra logging | - |
| `JETSCALE_DATA_DIR` | Filesystem path | - |
| `JETSCALE_DB_HOST` | Database connection | - |
| `JETSCALE_DB_PORT` | Database connection | - |
| `JETSCALE_DB_NAME` | Database connection | - |
| `JETSCALE_DB_USER` | Database connection | - |
| `JETSCALE_DB_PASSWORD` | Database connection | Env Secret |
| `JETSCALE_JWT_SECRET_KEY` | Auth secret | Env Secret |
| `JETSCALE_JWT_ALGORITHM` | Auth config | - |
| `JETSCALE_FRONTEND_URL` | Deployment URL | - |
| `JETSCALE_AWS_ACCESS_KEY_ID` | AWS credentials | Env Secret |
| `JETSCALE_AWS_SECRET_ACCESS_KEY` | AWS credentials | Env Secret |
| `JETSCALE_AWS_ACCOUNT_ID` | AWS identity | - |
| `JETSCALE_DEFAULT_ADMIN_EMAIL` | Bootstrap | - |
| `JETSCALE_DEFAULT_ADMIN_PASSWORD` | Bootstrap | Env Secret |

### Org Secrets (Optional Defaults - Client Can Override via UI)

These can be set as **org-level secrets** to provide defaults across all stacks.
Clients can override them via the System Settings UI.

| Env Var | Purpose | Override via UI |
|---------|---------|-----------------|
| `JETSCALE_ANTHROPIC_API_KEY` | LLM API key | ✅ `anthropic_api_key` |
| `JETSCALE_SMTP_SERVER` | Email server | ✅ `smtp_host` |
| `JETSCALE_SMTP_PASSWORD` | Email auth | ✅ `smtp_password` |
| `JETSCALE_LANGFUSE_SECRET_KEY` | Observability | ✅ `langfuse_secret_key` |

### Now in System Settings (Remove from Helm)

These can be removed from `values.yaml` as they're now configurable via UI:

```yaml
# REMOVE these from values.yaml - now in System Settings
# JETSCALE_ENABLE_LANGFUSE
# JETSCALE_ENABLE_CACHING
# JETSCALE_USE_MOCK_DATA
# JETSCALE_ANALYSIS_DEBUG_MODE
# JETSCALE_ANALYSIS_MODEL_NAME
# JETSCALE_ANALYSIS_TEMPERATURE
# JETSCALE_SQL_MODEL_NAME
# JETSCALE_SQL_TEMPERATURE
# JETSCALE_PLANNER_MODEL_NAME
# JETSCALE_PLANNER_TEMPERATURE
# JETSCALE_PLANNER_MAX_TOKENS
# JETSCALE_RECOMMENDATION_MODEL_NAME
# JETSCALE_RECOMMENDATION_TEMPERATURE
# JETSCALE_SQL_MAX_RESULTS_LIMIT
# JETSCALE_SQL_TIMEOUT
# JETSCALE_MAX_CONCURRENT_APIS
# JETSCALE_API_TIMEOUT
# JETSCALE_MAX_RETRIES
# JETSCALE_EMAIL_RATE_LIMIT_PER_HOUR
# JETSCALE_IP_RATE_LIMIT_PER_HOUR
# JETSCALE_VERIFICATION_TOKEN_EXPIRE_MINUTES
# JETSCALE_MAX_VERIFICATION_ATTEMPTS
# JETSCALE_SMTP_PORT
# JETSCALE_SMTP_USERNAME
# JETSCALE_SMTP_TLS
# JETSCALE_SMTP_SSL
# JETSCALE_EMAIL_FROM
# JETSCALE_EMAIL_FROM_NAME
# JETSCALE_LANGFUSE_HOST
# JETSCALE_LANGFUSE_PUBLIC_KEY
# JETSCALE_AWS_REGION
# JETSCALE_CLIENT_AWS_REGION
# JETSCALE_CLIENT_AWS_ROLE_ARN
# JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID
# JETSCALE_AWS_ROLE_ARN
# JETSCALE_AWS_ROLE_EXTERNAL_ID
# JETSCALE_AWS_ASSUME_ROLE_DURATION_SECONDS
# JETSCALE_RECOMMENDATION_AGENT_ROLE_ARN
```

## Implementation Tasks

### Phase 1: Helm Chart Cleanup

- [ ] Audit current `values.yaml` for removable env vars
- [ ] Move app config vars to "optional overrides" section with comments
- [ ] Update `values.schema.json` to mark app config as optional
- [ ] Add documentation comments explaining System Settings

### Phase 2: Multi-Stack Support

- [ ] Test deploying 2+ stacks to same cluster
- [ ] Verify each stack has isolated `system_settings` table
- [ ] Document stack isolation requirements (separate DBs)

### Phase 3: Migration Guide

- [ ] Document migration path for existing deployments
- [ ] Create script to migrate env vars to System Settings DB
- [ ] Add helm upgrade notes

## values.yaml Structure (Proposed)

```yaml
# Infrastructure (REQUIRED)
infrastructure:
  database:
    host: ""
    port: 5432
    name: "jetscale"
    user: "jetscale"
    # password from secret

  auth:
    jwtAlgorithm: "HS256"
    # jwtSecretKey from secret

  network:
    host: "0.0.0.0"
    port: 8000
    frontendUrl: ""
    allowedOrigins: ""

  aws:
    accountId: ""
    # accessKeyId from secret
    # secretAccessKey from secret

# Secrets (from K8s secrets)
secrets:
  existingSecret: ""  # Name of existing secret
  # OR create new secret with these keys:
  dbPassword: ""
  jwtSecretKey: ""
  anthropicApiKey: ""      # Org default, client can override via UI
  awsAccessKeyId: ""
  awsSecretAccessKey: ""
  defaultAdminPassword: ""

# Application Config (OPTIONAL - org defaults, client can override via UI)
# These are only needed if you want to set org-wide defaults via env vars
# Otherwise, configure via Admin UI -> System Settings
appConfig:
  # Uncomment to set org-wide defaults (client can still override in UI)
  # anthropicApiKey: ""     # From secrets.anthropicApiKey
  # smtpHost: ""
  # smtpPassword: ""        # From secrets
  # langfuseSecretKey: ""   # From secrets
```

## Multi-Stack Deployment Example

```bash
# Stack 1: Production (uses org defaults)
helm install jetscale-prod ./stack \
  --set infrastructure.database.host=prod-db.cluster.local \
  --set infrastructure.network.frontendUrl=https://app.example.com \
  --set secrets.existingSecret=jetscale-prod-secrets

# Stack 2: Staging (uses org defaults)
helm install jetscale-staging ./stack \
  --set infrastructure.database.host=staging-db.cluster.local \
  --set infrastructure.network.frontendUrl=https://staging.example.com \
  --set secrets.existingSecret=jetscale-staging-secrets

# Stack 3: Client Demo (client brings own API key via UI)
helm install jetscale-demo ./stack \
  --set infrastructure.database.host=demo-db.cluster.local \
  --set infrastructure.network.frontendUrl=https://demo.example.com \
  --set secrets.existingSecret=jetscale-demo-secrets
  # Client configures their own JETSCALE_ANTHROPIC_API_KEY via System Settings UI
```

Each stack gets its own:

- Database (with isolated `system_settings` table)
- Admin UI for configuration
- Independent settings per environment
- Ability to override org defaults

## Database Isolation

**Critical**: Each stack MUST have its own database to ensure settings isolation.

```text
┌─────────────────────────────────────────────────────────────┐
│  EKS Cluster                                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ jetscale-   │  │ jetscale-   │  │ jetscale-   │         │
│  │ prod        │  │ staging     │  │ demo        │         │
│  │             │  │             │  │ (client     │         │
│  │ Uses org    │  │ Uses org    │  │  overrides  │         │
│  │ defaults    │  │ defaults    │  │  API key)   │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                 │
│         ▼                ▼                ▼                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ prod-db     │  │ staging-db  │  │ demo-db     │         │
│  │ (RDS/PG)    │  │ (RDS/PG)    │  │ (RDS/PG)    │         │
│  │             │  │             │  │             │         │
│  │ system_     │  │ system_     │  │ system_     │         │
│  │ settings:   │  │ settings:   │  │ settings:   │         │
│  │ (empty)     │  │ (empty)     │  │ anthropic_  │         │
│  │             │  │             │  │ api_key:    │         │
│  │             │  │             │  │ "sk-..."    │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Files to Update

```text
stack/
├── charts/backend/
│   ├── values.yaml          # Restructure env vars
│   ├── values.schema.json   # Update schema
│   └── templates/
│       └── deployment.yaml  # Update env var references
├── CHANGELOG.md             # Document changes
└── SYSTEM_TODO.md           # This file
```

## Out of Scope

- Shared settings across stacks (each stack is independent)
- Settings sync between environments
- GitOps for settings (settings live in DB, not git)
