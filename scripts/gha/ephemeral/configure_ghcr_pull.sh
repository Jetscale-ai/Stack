#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${JETSCALEBOT_GITHUB_TOKEN:?JETSCALEBOT_GITHUB_TOKEN is required}"

echo "🔐 Creating GHCR image pull secret for namespace ${ENV_ID}..."

kubectl create secret docker-registry ghcr-pull \
  --namespace "${ENV_ID}" \
  --docker-server=ghcr.io \
  --docker-username=jetscalebot \
  --docker-password="${JETSCALEBOT_GITHUB_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl patch serviceaccount default \
  --namespace "${ENV_ID}" \
  --type merge \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'

echo "✅ GHCR image pull credentials configured"
