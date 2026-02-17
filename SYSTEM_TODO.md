# System Settings - Configuration Lifecycle Guide

## Overview

This document defines the **configuration lifecycle** for all JetScale environment variables across all layers:

- **Day 0 (Deployment)**: Must be set before pods start; changing requires redeployment
- **Day 1 (Runtime - SystemSettings)**: Can be changed via admin UI without redeployment
- **Day 2 (Future)**: Planned for migration to runtime configuration

## Current Status: ✅ DEPLOYED (Feb 2026)

SystemSettings provides layered resolution (DB > ENV > Default) for **37 settings**.

### Critical Gaps Identified

1. **Consumer Gap**: Most agent code reads from `config.py` instead of `SystemSettingsService`
2. **Defaults Gap**: `config.py` has dev-friendly defaults that differ from ConfigMap prod defaults
3. **ConfigMap Bloat**: ConfigMap duplicates values that should come from `config.py` defaults

### New Direction: Production-Safe Defaults

**Principle**: `config.py` defaults should be **production-safe**. Development overrides via `.env`.

This enables:

- Removing ~25 redundant ConfigMap variables
- Safe behavior if ENV vars are missing
- Single source of truth for defaults

---

## Layer 1: Shared Infrastructure (Account-Level)

Resources shared across all clusters in the AWS account.

### Source: `iac/shared/`

| Resource | Path/ARN | Purpose | Change |
|----------|----------|---------|--------|
| Wildcard TLS Cert | `arn:aws:acm:us-east-1:134051052096:certificate/6e3e7f72-...` | `*.jetscale.ai` HTTPS | None - stable |
| Route53 Zone | `jetscale.ai` | DNS authority | None - stable |
| GitHub OIDC Provider | `arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com` | CI/CD auth | None - stable |
| Atlantis Target Role | `arn:aws:iam::134051052096:role/atlantis-target-live` | Cross-account TF | None - stable |
| DNS Authority Role | `arn:aws:iam::081373342681:role/jetscale-external-dns-dns-authority` | ExternalDNS | None - stable |

**Win Condition**: ✅ All shared infra is provisioned and stable. No changes needed.

---

## Layer 2: Cluster Infrastructure (Per-Cluster)

Resources created per EKS cluster by IaC.

### Source: `iac/clients/` + `iac/clients/variables/prod/jetscale.tfvars`

| Resource | Value | Type | Change |
|----------|-------|------|--------|
| **Cluster Name** | `jetscale-prod` | Terraform var | None |
| **AWS Account** | `134051052096` | Terraform var | None |
| **AWS Region** | `us-east-1` | Terraform var | None |
| **EKS Version** | `1.33` | Terraform var | None |
| **VPC CIDR** | `10.2.0.0/16` | Terraform var | None |
| **Domain** | `jetscale.ai` | Terraform var | None |

### AWS Secrets Manager (IaC-Managed)

| Secret Path | Contents | Source | Change |
|-------------|----------|--------|--------|
| `jetscale-prod/database/admin` | `username`, `password`, `host`, `port`, `dbname` | Terraform `random_password` | None - auto-generated |
| `jetscale-prod/database/postgres` | Same as admin (DEPRECATED) | Terraform | **Remove** after console migrates |
| `jetscale-prod/application/backend/redis` | `redis-endpoint` | Terraform (ElastiCache output) | None - auto-populated |
| `jetscale-prod/application/encryption_key` | `APP_ENCRYPTION_KEY` | `var.frontend_encryption_key` | None - set in tfvars |
| `jetscale-prod/application/aws/client` | Container only (empty) | Terraform | **Remove** - now Day 1 via SystemSettings |

### IAM Roles (IRSA)

| Role | ARN | Purpose | Change |
|------|-----|---------|--------|
| App Role | `arn:aws:iam::134051052096:role/jetscale-prod-app-role` | Application pods | None |
| ESO Role | `arn:aws:iam::134051052096:role/jetscale-prod-external-secrets-role` | External Secrets | None |
| Discovery Role | `arn:aws:iam::134051052096:role/jetscale-prod-client-discovery-role` | AWS resource discovery | None |

**Win Condition**:

- [x] Cluster infrastructure provisioned
- [ ] Remove deprecated `database/postgres` secret after console migration
- [ ] Remove empty `application/aws/client` container (now Day 1)

---

## Layer 3: Helm Values (Per-Project)

Configuration set at Helm install/upgrade time.

### Source: `stack/envs/prod/console.yaml`, `stack/envs/prod/demo.yaml`, `stack/envs/aws.yaml`

### ExternalSecrets Configuration

| Setting | Console | Demo | Type | Change |
|---------|---------|------|------|--------|
| `externalSecret.enabled` | `true` | `true` | Helm value | None |
| `externalSecret.awsRegion` | `us-east-1` | `us-east-1` | Helm value | None |
| `externalSecret.awsSecretPrefix` | `jetscale-prod` | `jetscale-prod` | Helm value | None |
| `externalSecret.irsaRoleArn` | `...external-secrets-role` | Same | Helm value | None |
| `externalSecret.db.enabled` | `true` | `true` | Helm value | None |
| `externalSecret.db.secretPath` | `jetscale-prod/database/postgres` | (default) | Helm value | **Migrate** console to per-project |
| `externalSecret.redis.enabled` | `true` | `false` | Helm value | None |
| `externalSecret.common.enabled` | `true` | `true` | Helm value | None |
| `externalSecret.awsClient.enabled` | `false` | `false` | Helm value | ✅ Done - now Day 1 |

### Kubernetes Secrets (Created by ExternalSecrets)

| K8s Secret | AWS SM Source | Variables Injected | Change |
|------------|---------------|-------------------|--------|
| `{release}-db-secret` | `jetscale-prod/database/{project}` | `JETSCALE_DB_*`, `JETSCALE_DATABASE_URL` | None |
| `{release}-redis-secret` | `jetscale-prod/application/backend/redis` | `JETSCALE_REDIS_HOST`, `JETSCALE_REDIS_SSL` | None |
| `{release}-common-secrets` | `jetscale-prod/application/encryption_key` | `JETSCALE_ENCRYPTION_SECRET_KEY` | None |
| `{release}-aws-client-secret` | (disabled) | N/A | ✅ **Removed** - now Day 1 |

### ConfigMap Strategy: Minimal Day 0 Only

**Current Problem**: ConfigMap has ~35 variables, most duplicating `config.py` defaults.

**New Strategy**: ConfigMap should only contain **true Day 0** variables that:

1. Are consumed at process startup (before DB available)
2. Are container/runtime specific (not application logic)
3. Cannot have safe defaults in code

### ConfigMap Variables: Keep vs Remove

| Variable | Keep? | Reason |
|----------|-------|--------|
| `JETSCALE_HOST` | **Keep** | uvicorn bind - Day 0 |
| `JETSCALE_PORT` | **Keep** | uvicorn bind - Day 0 |
| `JETSCALE_DEBUG` | **Remove** | Fix default in `config.py` → `False` |
| `JETSCALE_ENVIRONMENT` | **Remove** | Fix default in `config.py` → `RELEASE` |
| `JETSCALE_DB_PORT` | **Keep** | SQLAlchemy engine - Day 0 |
| `AWS_DEFAULT_REGION` | **Keep** | AWS SDK init - Day 0 |
| `JETSCALE_DATA_DIR` | **Remove** | Fix default in `config.py` → `/app/data` |
| `JETSCALE_FRONTEND_URL` | **Keep** | CORS middleware - Day 0 (computed) |
| `JETSCALE_CORS_*` | **Keep** | CORS middleware - Day 0 |
| `PYTHONDONTWRITEBYTECODE` | **Keep** | Python runtime |
| `PYTHONUNBUFFERED` | **Keep** | Python runtime |
| `FORWARDED_ALLOW_*` | **Keep** | Proxy config - Day 0 |
| `ROOT_PATH` | **Keep** | FastAPI mount - Day 0 |
| `USE_X_FORWARDED_*` | **Keep** | Proxy config - Day 0 |
| `JETSCALE_EVENTBUS_WORKERS` | **Keep** | Worker pool - Day 0 (startup) |
| `JETSCALE_EVENTBUS_MAX_QUEUE_SIZE` | **Keep** | Queue init - Day 0 (startup) |
| All `JETSCALE_PLANNER_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| All `JETSCALE_RECOMMENDATION_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| All `JETSCALE_SMTP_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| All `JETSCALE_*_RATE_LIMIT_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| All `JETSCALE_VERIFICATION_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| `JETSCALE_ENABLE_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| `JETSCALE_LANGFUSE_*` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| `JETSCALE_API_TIMEOUT` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| `JETSCALE_MAX_RETRIES` | **Remove** | Fix defaults in `config.py`, use SystemSettings |
| `JETSCALE_CRON_BATCH_SIZE` | **Remove** | Fix defaults in `config.py`, use SystemSettings |

### Target ConfigMap (After Cleanup)

```yaml
# cm-app.yaml - MINIMAL (Day 0 only)
data:
  # Server binding (Day 0)
  JETSCALE_HOST: "0.0.0.0"
  JETSCALE_PORT: "8000"
  JETSCALE_DB_PORT: "5432"
  AWS_DEFAULT_REGION: "us-east-1"

  # CORS (Day 0 - computed)
  JETSCALE_FRONTEND_URL: "{{ computed }}"
  JETSCALE_CORS_ALLOWED_ORIGINS: "{{ computed }}"
  JETSCALE_CORS_ALLOWED_METHODS: "GET,POST,PUT,DELETE,OPTIONS"
  JETSCALE_CORS_ALLOWED_HEADERS: "Content-Type,Authorization,X-Requested-With"

  # EventBus (Day 0 - startup)
  JETSCALE_EVENTBUS_WORKERS: "5"
  JETSCALE_EVENTBUS_MAX_QUEUE_SIZE: "500"

  # Python/Proxy runtime
  PYTHONDONTWRITEBYTECODE: "1"
  PYTHONUNBUFFERED: "1"
  FORWARDED_ALLOW_IPS: "*"
  FORWARDED_ALLOW_HOSTS: "*"
  ROOT_PATH: ""
  USE_X_FORWARDED_HOST: "true"
  USE_X_FORWARDED_PORT: "true"
  USE_X_FORWARDED_PREFIX: "true"
```

**Win Condition**:

- [x] ExternalSecrets bridging AWS SM → K8s secrets
- [x] `aws-client-secret` removed from envFrom
- [ ] Migrate console to per-project database secret
- [ ] Fix `config.py` defaults to be production-safe
- [ ] Remove redundant ConfigMap variables (~25)

---

## Layer 4: Backend Defaults (`config.py`)

### Source: `backend/config.py`

### Defaults to Fix (Dev → Prod Safe)

| Variable | Current Default | Prod-Safe Default | Risk if Unchanged |
|----------|-----------------|-------------------|-------------------|
| `debug` | `True` | **`False`** | Exposes stack traces |
| `environment` | `DEBUG` | **`RELEASE`** | Enables debug features |
| `host` | `127.0.0.1` | **`0.0.0.0`** | Pod won't accept traffic |
| `use_mock_data` | `True` | **`False`** | Returns fake data in prod! |
| `data_dir` | `data` | **`/app/data`** | Path mismatch in container |
| `planner_max_tokens` | `2000` | **`4000`** | Truncated responses |
| `recommendation_model_name` | `""` | **`claude-sonnet-4-5-20250929`** | Agent fails |
| `max_concurrent_recommendations` | `5` | **`3`** | Resource exhaustion |
| `eventbus_workers` | `10` | **`5`** | Resource exhaustion |
| `verification_token_expire_minutes` | `60` | **`30`** | Longer exposure window |
| `langfuse_host` | `https://cloud.langfuse.com` | **`https://us.cloud.langfuse.com`** | Wrong region |

### Defaults Already Correct (No Change)

| Variable | Default | Status |
|----------|---------|--------|
| `planner_model_name` | `claude-sonnet-4-20250514` | ✅ |
| `planner_temperature` | `0.1` | ✅ |
| `planner_timeout` | `60` | ✅ |
| `recommendation_temperature` | `0.1` | ✅ |
| `api_timeout` | `60` | ✅ |
| `max_retries` | `3` | ✅ |
| `cron_batch_size` | `10` | ✅ |
| `smtp_port` | `587` | ✅ |
| `smtp_tls` | `True` | ✅ |
| `email_from` | `noreply@jetscale.ai` | ✅ |
| `enable_langfuse` | `True` | ✅ |
| All rate limits | Match ConfigMap | ✅ |

**Win Condition**:

- [ ] Fix 11 defaults in `config.py` to be production-safe
- [ ] Update `.env.example` with dev overrides

---

## Layer 5: SystemSettings (Runtime)

Settings configurable via admin UI without redeployment.

### Source: `backend/api_v2/Modules/System/Services/SystemSettingsService.py`

### ✅ Fully Working (DB > ENV > Default at Runtime)

| SystemSettings Key | ENV Override | Default | Consumer |
|--------------------|--------------|---------|----------|
| `client_aws_region` | `JETSCALE_CLIENT_AWS_REGION` | `""` | `get_client_aws_config()` |
| `client_aws_role_arn` | `JETSCALE_CLIENT_AWS_ROLE_ARN` | `""` | `get_client_aws_config()` |
| `client_aws_role_external_id` | `JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID` | `""` | `get_client_aws_config()` |

### ⚠️ Defined but Not Consumed at Runtime (34 settings)

These exist in SystemSettings but agents read from `config.py`. After fixing `config.py` defaults, these will work correctly via ENV fallback, but won't be runtime-configurable until consumer migration.

| Category | Settings | Consumer to Migrate |
|----------|----------|---------------------|
| API Keys | `anthropic_api_key` | `agents/base_agent.py` |
| Feature Flags | `enable_langfuse`, `enable_caching`, `use_mock_data`, `analysis_debug_mode`, `enable_enumeration_protection` | Various |
| Model Config | `planner_*` (3), `recommendation_*` (2) | `agents/planner_agent/`, `agents/recommendation_agent_v3/` |
| Rate Limits | `max_concurrent_apis`, `api_timeout`, `max_retries`, `*_rate_limit_*` (3) | `middleware/rate_limiting.py` |
| Security | `verification_token_expire_minutes`, `max_verification_attempts` | Auth services |
| SMTP | `smtp_*` (8) | `services/email.py` |
| Observability | `langfuse_*` (3) | `agents/langfuse_client.py` |
| AWS | `aws_region`, `aws_role_arn`, `aws_role_external_id`, `aws_assume_role_duration_seconds`, `recommendation_agent_role_arn` | AWS services |

### Not in SystemSettings (Day 2 Candidates - 21 settings)

| Category | Settings to Add |
|----------|-----------------|
| SQL Tool | `sql_model_name`, `sql_temperature`, `sql_max_results_limit`, `sql_timeout` |
| CloudWatch Agent | `cloudwatch_agent_model`, `cloudwatch_agent_temperature`, `cloudwatch_agent_timeout`, `cloudwatch_agent_max_retries` |
| Recommendation | `recommendation_max_retry_attempts`, `recommendation_timeout_seconds`, `recommendation_max_tokens`, `recommendation_llm_max_retries`, `recommendation_hours_per_month`, `ec2_memory_headroom_percent` |
| CloudWatch Tool | `cloudwatch_tool_lookback_days`, `client_cloudwatch_agent_namespaces` |
| Discovery | `discovery_sync_threshold_minutes` |
| Cron | `cron_batch_size`, `cron_retry_failed` |
| Auth | `jwt_access_token_expire_minutes`, `jwt_refresh_token_expire_days` |

**Win Condition**:

- [x] 3 settings fully working at runtime
- [ ] Migrate 34 settings to use SystemSettingsService (for true runtime config)
- [ ] Add 21 missing settings to SystemSettings

---

## Summary: Win Conditions by Layer

| Layer | Status | Win Condition | Action Items |
|-------|--------|---------------|--------------|
| **1. Shared Infra** | ✅ Complete | All shared resources stable | None |
| **2. Cluster Infra** | ⚠️ Cleanup | Remove deprecated secrets | Remove `database/postgres`, `aws/client` |
| **3. Helm/ConfigMap** | ⚠️ Bloated | Minimal Day 0 ConfigMap | Remove ~25 redundant vars |
| **4. Backend Defaults** | 🔴 Unsafe | Prod-safe defaults | Fix 11 defaults in `config.py` |
| **5. SystemSettings** | ⚠️ Partial | All settings consumed at runtime | Migrate agent code |

---

## Implementation Phases

### Phase 1: Fix Backend Defaults (FIRST - Enables All Other Phases)

Update `backend/config.py`:

```python
# SECURITY: Production-safe defaults
debug: bool = False                    # Was: True
environment: str = "RELEASE"           # Was: "DEBUG"
host: str = "0.0.0.0"                  # Was: "127.0.0.1"
use_mock_data: bool = False            # Was: True (CRITICAL!)
data_dir: str = "/app/data"            # Was: "data"

# OPERATIONAL: Match prod expectations
planner_max_tokens: int = 4000         # Was: 2000
recommendation_model_name: str = "claude-sonnet-4-5-20250929"  # Was: ""
max_concurrent_recommendations: int = 3  # Was: 5
eventbus_workers: int = 5              # Was: 10
verification_token_expire_minutes: int = 30  # Was: 60
langfuse_host: str = "https://us.cloud.langfuse.com"  # Was: EU
```

Update `backend/.env.example` with dev overrides:

```bash
# Development overrides (not needed in prod)
JETSCALE_DEBUG=true
JETSCALE_ENVIRONMENT=DEBUG
JETSCALE_USE_MOCK_DATA=true
JETSCALE_HOST=127.0.0.1
JETSCALE_DATA_DIR=data
```

### Phase 2: Slim Down ConfigMap

After Phase 1, remove from `charts/jetscale/templates/cm-app.yaml`:

- All `JETSCALE_PLANNER_*`
- All `JETSCALE_RECOMMENDATION_*`
- All `JETSCALE_SMTP_*`
- All `JETSCALE_*_RATE_LIMIT_*`
- All `JETSCALE_VERIFICATION_*`
- `JETSCALE_ENABLE_*`
- `JETSCALE_LANGFUSE_*`
- `JETSCALE_API_TIMEOUT`, `JETSCALE_MAX_RETRIES`
- `JETSCALE_CRON_BATCH_SIZE`
- `JETSCALE_DEBUG`, `JETSCALE_ENVIRONMENT`
- `JETSCALE_DATA_DIR`
- `JETSCALE_EVENTBUS_RESULT_TTL`, `JETSCALE_EVENTBUS_MAX_RESULTS`

### Phase 3: IaC Cleanup

- [ ] Remove `jetscale-prod/application/aws/client` secret container
- [ ] Migrate console to per-project database secret
- [ ] Remove deprecated `jetscale-prod/database/postgres` secret

### Phase 4: Consumer Migration (Backend)

Migrate agents to use `SystemSettingsService` for true runtime configurability:

| Priority | Component | Settings |
|----------|-----------|----------|
| **Critical** | `agents/base_agent.py` | `anthropic_api_key` |
| High | `agents/planner_agent/utils.py` | `planner_*` |
| High | `agents/recommendation_agent_v3/` | `recommendation_*` |
| High | `agents/cloudwatch_agent/nodes.py` | `cloudwatch_agent_*` |
| Medium | `agents/tools/sql_tools.py` | `sql_*` |
| Medium | `services/email.py` | `smtp_*` |
| Low | `agents/langfuse_client.py` | `langfuse_*` |
| Low | `middleware/rate_limiting.py` | `*_rate_limit_*` |

### Phase 5: Add Missing Settings

Add to `SETTINGS_DEFINITIONS` in `SystemSettingsService.py`:

- SQL tool settings (4)
- CloudWatch agent settings (4)
- Recommendation agent settings (6)
- Cron settings (2)
- JWT settings (2)
- Discovery settings (1)
- CloudWatch tool settings (2)

---

## Architecture

```text
Resolution order: DB > ENV > Default

┌─────────────────────────────────────────────────────────────┐
│  DB (admin UI)     - HIGHEST PRIORITY                       │
│  Per-project settings, configured via System Settings UI    │
├─────────────────────────────────────────────────────────────┤
│  ENV (Helm/K8s)    - FALLBACK (Org Defaults)                │
│  Minimal ConfigMap for true Day 0 only                      │
├─────────────────────────────────────────────────────────────┤
│  Default (config.py) - PRODUCTION-SAFE                      │
│  Safe defaults that work in prod without any config         │
└─────────────────────────────────────────────────────────────┘
```

**Key Principle**: Development should override defaults, not production.

- Prod relies on safe `config.py` defaults + explicit secrets
- Dev uses `.env` to opt-in to unsafe settings (`DEBUG=true`, `USE_MOCK_DATA=true`)

---

## Multi-Project Deployment

```bash
# Project 1: Console (production)
helm install jetscale-console ./stack \
  -f envs/aws.yaml \
  -f envs/prod/console.yaml

# Project 2: Demo
helm install jetscale-demo ./stack \
  -f envs/aws.yaml \
  -f envs/prod/demo.yaml
```

Each project gets:

- Own namespace and database
- Own `system_settings` table
- Independent Day 1 configuration via UI

---

## Files Reference

```text
iac/
├── clients/
│   ├── variables/prod/jetscale.tfvars  # Cluster config
│   ├── secrets.tf                       # AWS SM secrets
│   └── iam.tf                           # IRSA roles
└── shared/
    └── acm-live/                        # Wildcard cert

stack/
├── envs/
│   ├── aws.yaml                         # AWS-specific Helm values
│   └── prod/
│       ├── console.yaml                 # Console project config
│       └── demo.yaml                    # Demo project config
├── charts/jetscale/
│   ├── templates/
│   │   ├── cm-app.yaml                  # ConfigMap (to be slimmed)
│   │   ├── ext-secret-db.yaml           # DB ExternalSecret
│   │   ├── ext-secret-redis.yaml        # Redis ExternalSecret
│   │   ├── ext-secret-common.yaml       # Common ExternalSecret
│   │   └── ext-secret-aws-client.yaml   # AWS Client (disabled)
│   └── values.yaml                      # Default values
└── SYSTEM_TODO.md                       # This file

backend/
├── config.py                            # Defaults (to be fixed)
├── .env.example                         # Dev overrides
└── api_v2/Modules/System/Services/
    └── SystemSettingsService.py         # Runtime settings
```
