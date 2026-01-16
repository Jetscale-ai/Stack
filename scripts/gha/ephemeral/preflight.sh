#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"

REGION="${AWS_REGION:-us-east-1}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[preflight] env_id=${ENV_ID} cluster=${CLUSTER_NAME} region=${REGION} kubeconfig=${KUBECONFIG}"

mkdir -p "$(dirname "${KUBECONFIG}")"

echo "🔍 Checking EKS cluster exists..."
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null

echo "📦 Ensuring namespace exists: ${ENV_ID}"
kubectl get namespace "${ENV_ID}" >/dev/null 2>&1 || kubectl create namespace "${ENV_ID}"

echo "⏳ Preflight: External Secrets Operator readiness"
if ! kubectl -n external-secrets-system rollout status deploy/external-secrets --timeout=5m; then
  echo "::error::External Secrets Operator is not ready (external-secrets-system/deploy/external-secrets)"
  kubectl -n external-secrets-system get deploy,pods -o wide || true
  kubectl -n external-secrets-system get events --sort-by=.metadata.creationTimestamp | tail -n 120 || true
  exit 1
fi

echo "🔐 Preflight: AWS client secret contract (Secrets Manager -> ESO -> Kubernetes)"
"${SCRIPT_DIR}/ensure_secrets.sh"

echo "🔐 Preflight: Registry pull secret (jetscale-registry-secret)"
if kubectl -n "${ENV_ID}" get secret jetscale-registry-secret >/dev/null 2>&1; then
  echo "✅ Found Kubernetes secret: ${ENV_ID}/jetscale-registry-secret"
else
  : "${JETSCALEBOT_GHCR_PULL_TOKEN:?JETSCALEBOT_GHCR_PULL_TOKEN is required to create jetscale-registry-secret}"
  kubectl -n "${ENV_ID}" create secret docker-registry jetscale-registry-secret \
    --docker-server=ghcr.io \
    --docker-username=jetscalebot \
    --docker-password="${JETSCALEBOT_GHCR_PULL_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✅ Created Kubernetes secret: ${ENV_ID}/jetscale-registry-secret"
fi

echo "✅ Preflight OK"

