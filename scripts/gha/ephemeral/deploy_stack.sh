#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region us-east-1

echo "⏳ Waiting for AWS Load Balancer Controller..."
kubectl wait --for=condition=available deployment -n kube-system aws-load-balancer-controller --timeout=5m

helm registry login ghcr.io --username jetscalebot --password "${JETSCALEBOT_GITHUB_TOKEN:?JETSCALEBOT_GITHUB_TOKEN is required}"
(cd charts/jetscale && helm dependency build)

helm upgrade --install jetscale-stack charts/jetscale \
  --namespace "${ENV_ID}" \
  --create-namespace \
  --atomic \
  --values envs/preview/values.yaml \
  --set-string global.env=ephemeral \
  --set-string global.client_name="${ENV_ID}" \
  --set-string global.tenant_id="${ENV_ID}" \
  --set-string frontend.env.VITE_API_BASE_URL="https://${PUBLIC_HOST}" \
  --set-string ingress.hosts[0].host="${PUBLIC_HOST}" \
  --set-string ingress.annotations."external-dns\.alpha\.kubernetes\.io/hostname"="${PUBLIC_HOST}" \
  --set-string backend.envFrom[0].secretRef.name="${ENV_ID}-db-secret" \
  --set-string backend.envFrom[1].secretRef.name="${ENV_ID}-redis-secret" \
  --set-string backend.envFrom[2].secretRef.name="${ENV_ID}-common-secrets" \
  --set-string backend.envFrom[3].secretRef.name="${ENV_ID}-aws-client-secret" \
  --wait --timeout 15m
