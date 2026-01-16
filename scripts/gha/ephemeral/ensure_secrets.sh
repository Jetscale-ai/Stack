#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

SECRET_ID="${ENV_ID}-ephemeral/application/aws/client"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ENV_ID}-ephemeral-client-discovery-role"
DEFAULT_SECRET_JSON="$(cat <<EOF
{
  "JETSCALE_CLIENT_AWS_REGION": "${REGION}",
  "JETSCALE_CLIENT_AWS_ROLE_ARN": "${ROLE_ARN}",
  "JETSCALE_CLIENT_AWS_ROLE_EXTERNAL_ID": ""
}
EOF
)"

SECRET_JSON="${AWS_CLIENT_SECRET_JSON:-${DEFAULT_SECRET_JSON}}"
echo "${SECRET_JSON}" | jq -e . >/dev/null

set +e
aws secretsmanager describe-secret --secret-id "${SECRET_ID}" --region "${REGION}" >/dev/null 2>&1
DESCRIBE_RC=$?
aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" --region "${REGION}" --version-stage AWSCURRENT >/dev/null 2>&1
CURRENT_RC=$?
set -e

if [[ "${DESCRIBE_RC}" -ne 0 ]]; then
  aws secretsmanager create-secret \
    --name "${SECRET_ID}" \
    --description "Ephemeral AWS client discovery config (ESO -> ${ENV_ID}-aws-client-secret)" \
    --secret-string "${SECRET_JSON}" \
    --region "${REGION}"
elif [[ "${CURRENT_RC}" -ne 0 ]]; then
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_ID}" \
    --secret-string "${SECRET_JSON}" \
    --region "${REGION}"
else
  echo "✅ Secrets Manager secret exists with AWSCURRENT value: ${SECRET_ID}"
fi

kubectl -n external-secrets-system rollout restart deploy/external-secrets || true

echo "⏳ Waiting for ESO to create Kubernetes secret: ${ENV_ID}-aws-client-secret"
for i in $(seq 1 60); do
  if kubectl -n "${ENV_ID}" get secret "${ENV_ID}-aws-client-secret" >/dev/null 2>&1; then
    echo "✅ Found Kubernetes secret: ${ENV_ID}-aws-client-secret"
    exit 0
  fi
  sleep 5
done

echo "::error::Timed out waiting for ${ENV_ID}-aws-client-secret"
kubectl -n "${ENV_ID}" get externalsecret "${ENV_ID}-aws-client-secret" -o wide || true
kubectl -n "${ENV_ID}" describe externalsecret "${ENV_ID}-aws-client-secret" || true
exit 1
