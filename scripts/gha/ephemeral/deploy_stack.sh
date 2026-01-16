#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${PUBLIC_HOST:?PUBLIC_HOST is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"

RELEASE="${ENV_ID}"

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
  cronJobs:
    pull-coh:
      suspend: true
    pull-co:
      suspend: true
    discover-aws:
      suspend: true
    generate-from-coh:
      suspend: true
    generate-from-discovery:
      suspend: true

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
  cronJobs:
    pull-coh:
      suspend: true
    pull-co:
      suspend: true
    discover-aws:
      suspend: true
    generate-from-coh:
      suspend: true
    generate-from-discovery:
      suspend: true
EOF

# Ensure required Secret exists for backend chart envFrom.
kubectl -n "${ENV_ID}" create secret generic "${RELEASE}-app-secrets" \
  --from-literal=JETSCALE_PLACEHOLDER="true" \
  --dry-run=client -o yaml | kubectl apply -f -

# Reset legacy/failed releases to avoid name drift across iterations.
echo "🧹 Reset Helm releases (best-effort)"
if helm -n "${ENV_ID}" status jetscale >/dev/null 2>&1; then
  echo "Found legacy release 'jetscale' in namespace; uninstalling..."
  helm -n "${ENV_ID}" uninstall jetscale --wait --timeout 5m || true
fi
set +e
STATUS="$(helm -n "${ENV_ID}" status "${RELEASE}" 2>/dev/null | awk '/^STATUS:/ {print $2}')"
set -e
if [[ "${STATUS:-}" == "failed" ]]; then
  echo "Release ${RELEASE} is failed; uninstalling to reset before install/upgrade..."
  helm -n "${ENV_ID}" uninstall "${RELEASE}" --wait --timeout 5m || true
fi

helm upgrade --install "${RELEASE}" charts/jetscale \
  --namespace "${ENV_ID}" \
  --create-namespace \
  --atomic \
  --values envs/aws.yaml \
  --values envs/preview/preview.yaml \
  --values "${CLEAR_HOSTS_VALUES}" \
  --values "${EPHEMERAL_VALUES}" \
  --wait --timeout 15m
