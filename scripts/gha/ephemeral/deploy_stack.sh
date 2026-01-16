#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/helm_helpers.sh"

: "${ENV_ID:?ENV_ID is required}"
: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${JETSCALEBOT_GITHUB_TOKEN:?JETSCALEBOT_GITHUB_TOKEN is required}"
: "${JETSCALEBOT_GHCR_PULL_TOKEN:?JETSCALEBOT_GHCR_PULL_TOKEN is required}"

REGION="${AWS_REGION:-us-east-1}"

# Canonical env inheritance inputs.
ENV_TYPE="${ENV_TYPE:-preview}"
CLIENT_NAME="${CLIENT_NAME:-preview}"
CLOUD="${CLOUD:-aws}"

# Phase 3.2 will codify naming more formally; for now keep the defaults.
NAMESPACE="${NAMESPACE:-${ENV_ID}}"
RELEASE="${RELEASE:-${ENV_ID}}"
CHART_PATH="${CHART_PATH:-charts/jetscale}"
HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"
HELM_ATOMIC="${HELM_ATOMIC:-false}"

echo "[deploy_stack] env_id=${ENV_ID} namespace=${NAMESPACE} release=${RELEASE} cluster=${CLUSTER_NAME} region=${REGION}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo "⏳ Waiting for AWS Load Balancer Controller..."
kubectl wait --for=condition=available deployment -n kube-system aws-load-balancer-controller --timeout=5m

echo "📦 Ensuring namespace exists: ${NAMESPACE}"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

echo "🔐 Precreate registry pull secret: jetscale-registry-secret"
kubectl -n "${NAMESPACE}" create secret docker-registry jetscale-registry-secret \
  --docker-server=ghcr.io \
  --docker-username=jetscalebot \
  --docker-password="${JETSCALEBOT_GHCR_PULL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Avoid leaking passwords in process args (and suppress Helm warning).
echo "${JETSCALEBOT_GITHUB_TOKEN}" | helm registry login ghcr.io --username jetscalebot --password-stdin

echo "[deploy_stack] helm dependency build ${CHART_PATH}"
helm dependency build "${CHART_PATH}"

VALUES_ARGS=()
helm_build_values_args VALUES_ARGS "${ENV_TYPE}" "${CLIENT_NAME}" "${CLOUD}"
echo "[deploy_stack] values args: ${VALUES_ARGS[*]} (+ generated overrides)"

# Compose Helm values using the env inheritance model:
# - envs/<cloud>.yaml (cloud)
# - envs/<type>/default.yaml (env defaults, optional)
# - envs/<type>/<client>.yaml (env client)
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

externalSecret:
  app:
    enabled: false

frontend:
  imagePullSecrets:
    - name: jetscale-registry-secret
  env:
    VITE_API_BASE_URL: "https://${PUBLIC_HOST}"

ingress:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "${PUBLIC_HOST}"
  hosts:
    ${PUBLIC_HOST}:

backend-api:
  imagePullSecrets:
    - name: jetscale-registry-secret
  serviceAccount:
    create: false
    name: "${ENV_ID}-service-account"
  envFrom:
    config: configMapRef
    db-secret: secretRef
    redis-secret: secretRef
    common-secrets: secretRef
    aws-client-secret: secretRef

backend-ws:
  imagePullSecrets:
    - name: jetscale-registry-secret
  serviceAccount:
    create: false
    name: "${ENV_ID}-service-account"
  envFrom:
    config: configMapRef
    db-secret: secretRef
    redis-secret: secretRef
    common-secrets: secretRef
    aws-client-secret: secretRef
EOF

# Ensure required Secret exists for backend chart envFrom.
kubectl -n "${NAMESPACE}" create secret generic "${RELEASE}-app-secrets" \
  --from-literal=JETSCALE_PLACEHOLDER="true" \
  --dry-run=client -o yaml | kubectl apply -f -

# Reset legacy/failed releases to avoid name drift across iterations.
echo "🧹 Reset Helm releases (best-effort)"
if helm -n "${NAMESPACE}" status jetscale >/dev/null 2>&1; then
  echo "Found legacy release 'jetscale' in namespace; uninstalling..."
  helm -n "${NAMESPACE}" uninstall jetscale --wait --timeout 5m || true
fi
if helm -n "${NAMESPACE}" status jetscale-stack >/dev/null 2>&1; then
  echo "Found legacy release 'jetscale-stack' in namespace; uninstalling..."
  helm -n "${NAMESPACE}" uninstall jetscale-stack --wait --timeout 5m || true
fi
set +e
STATUS="$(helm -n "${NAMESPACE}" status "${RELEASE}" 2>/dev/null | awk '/^STATUS:/ {print $2}')"
set -e
if [[ "${STATUS:-}" == "failed" ]]; then
  echo "Release ${RELEASE} is failed; uninstalling to reset before install/upgrade..."
  helm -n "${NAMESPACE}" uninstall "${RELEASE}" --wait --timeout 5m || true
fi

HELM_ARGS=(
  upgrade --install "${RELEASE}" "${CHART_PATH}"
  --namespace "${NAMESPACE}"
  --create-namespace
  "${VALUES_ARGS[@]}"
  --values "${CLEAR_HOSTS_VALUES}"
  --values "${EPHEMERAL_VALUES}"
  --wait --timeout "${HELM_TIMEOUT}"
)
if [[ "${HELM_ATOMIC}" == "true" ]]; then
  HELM_ARGS+=(--atomic)
fi

# Run non-atomic by default so we can capture diagnostics on failure.
set +e
helm "${HELM_ARGS[@]}"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  echo "::group::Diagnostics: Helm install failed (${RELEASE})"
  echo "env_id=${ENV_ID}"
  echo "namespace=${NAMESPACE}"
  echo "public_host=${PUBLIC_HOST}"
  helm -n "${NAMESPACE}" status "${RELEASE}" || true
  helm -n "${NAMESPACE}" get all "${RELEASE}" || true
  echo "--- kubectl: pods"
  kubectl -n "${NAMESPACE}" get pods -o wide || true
  echo "--- kubectl: all"
  kubectl -n "${NAMESPACE}" get all -o wide || true
  echo "--- kubectl: events (ns)"
  kubectl -n "${NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 200 || true
  echo "--- kubectl: describe pods (ns)"
  kubectl -n "${NAMESPACE}" describe pods || true
  echo "--- kubectl: logs (recent, ns)"
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-backend-api --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=15m || true
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-backend-ws --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=15m || true
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-frontend --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=15m || true
  echo "--- kubectl: logs (previous, ns)"
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-backend-api --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=60m --previous || true
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-backend-ws --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=60m --previous || true
  kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}"-frontend --all-containers=true --tail=200 --prefix=true --ignore-errors=true --since=60m --previous || true
  echo "--- kube-system: pods"
  kubectl -n kube-system get pods -o wide || true
  echo "--- kube-system: events"
  kubectl -n kube-system get events --sort-by=.metadata.creationTimestamp | tail -n 120 || true
  echo "::endgroup::"

  echo "::group::Cleanup: uninstall failed helm release (best-effort)"
  helm -n "${NAMESPACE}" uninstall "${RELEASE}" --wait --timeout 5m || true
  echo "::endgroup::"

  exit "${rc}"
fi
