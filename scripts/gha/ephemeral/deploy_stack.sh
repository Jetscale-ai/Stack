#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region us-east-1

echo "⏳ Waiting for AWS Load Balancer Controller..."
kubectl wait --for=condition=available deployment -n kube-system aws-load-balancer-controller --timeout=5m

echo "${JETSCALEBOT_GITHUB_TOKEN:?JETSCALEBOT_GITHUB_TOKEN is required}" | helm registry login ghcr.io --username jetscalebot --password-stdin
(cd charts/jetscale && helm dependency build)

# Compose Helm values using the env inheritance model:
# - envs/aws.yaml (cloud)
# - envs/preview/preview.yaml (preview defaults)
# - generated overrides for this PR (host, tenant, ESO secrets)
#
# NOTE: The chart uses `ingress.hosts` as a map keyed by hostname, so we generate a tiny values file
# for the host to avoid brittle `--set` escaping.
VALUES_DIR="${RUNNER_TEMP:-/tmp}"
mkdir -p "${VALUES_DIR}"

# Clear any static hosts from env files (map keys cannot be removed by merge).
CLEAR_HOSTS_VALUES="${VALUES_DIR}/helm-values-clear-hosts-${ENV_ID}.yaml"
cat > "${CLEAR_HOSTS_VALUES}" <<EOF
ingress:
  hosts: null
EOF

EPHEMERAL_VALUES="${VALUES_DIR}/helm-values-ephemeral-${ENV_ID}.yaml"
cat > "${EPHEMERAL_VALUES}" <<EOF
global:
  env: "ephemeral"
  client_name: "${ENV_ID}"
  tenant_id: "${ENV_ID}"

frontend:
  env:
    VITE_API_BASE_URL: "https://${PUBLIC_HOST}"

ingress:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "${PUBLIC_HOST}"
  hosts:
    ${PUBLIC_HOST}:

backend-api:
  envFrom:
    - secretRef:
        name: "${ENV_ID}-db-secret"
    - secretRef:
        name: "${ENV_ID}-redis-secret"
    - secretRef:
        name: "${ENV_ID}-common-secrets"
    - secretRef:
        name: "${ENV_ID}-aws-client-secret"

backend-ws:
  envFrom:
    - secretRef:
        name: "${ENV_ID}-db-secret"
    - secretRef:
        name: "${ENV_ID}-redis-secret"
    - secretRef:
        name: "${ENV_ID}-common-secrets"
    - secretRef:
        name: "${ENV_ID}-aws-client-secret"
EOF

helm upgrade --install jetscale charts/jetscale \
  --namespace "${ENV_ID}" \
  --create-namespace \
  --atomic \
  --values envs/aws.yaml \
  --values envs/preview/preview.yaml \
  --values "${CLEAR_HOSTS_VALUES}" \
  --values "${EPHEMERAL_VALUES}" \
  --wait --timeout 15m
