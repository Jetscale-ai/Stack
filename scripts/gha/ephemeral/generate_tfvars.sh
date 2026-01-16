#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${TIMESTAMP:?TIMESTAMP is required}"

BUCKET="jetscale-terraform-state"
STATE_KEY="ephemeral/${ENV_ID}/terraform.tfstate"
STATE_PATH="/tmp/${ENV_ID}.tfstate.json"

VPC_CIDR=""
# IMPORTANT: `aws s3 ls s3://bucket/key` can exit 0 even if the key doesn't exist.
# Use an exact HEAD check so we don't fail later with a 404 (HeadObject).
set +e
aws s3api head-object --bucket "${BUCKET}" --key "${STATE_KEY}" >/dev/null 2>&1
STATE_EXISTS_RC=$?
set -e
if [[ "${STATE_EXISTS_RC}" -eq 0 ]]; then
  echo "🔒 State exists for ${ENV_ID}; reusing VPC CIDR from state to prevent replacement."
  aws s3 cp "s3://${BUCKET}/${STATE_KEY}" "${STATE_PATH}" >/dev/null
  VPC_CIDR="$(jq -r '
    .resources[]
    | select(.type=="aws_vpc" and .name=="main")
    | .instances[0].attributes.cidr_block
    ' "${STATE_PATH}" 2>/dev/null || true)"

  if [[ -z "${VPC_CIDR:-}" || "${VPC_CIDR}" == "null" ]]; then
    echo "::error::State exists but could not determine aws_vpc.main.cidr_block from ${STATE_KEY}. Refusing to proceed (prevents destructive replacement)."
    exit 1
  fi
else
  PR="${PR_NUMBER:-0}"
  if ! echo "$PR" | grep -Eq '^[0-9]+$'; then
    PR=0
  fi
  OCTET=$(( (PR % 200) + 20 ))
  VPC_CIDR="10.${OCTET}.0.0/16"
  echo "🧮 No state found; computed deterministic VPC CIDR: ${VPC_CIDR}"
fi

cat > ephemeral.auto.tfvars.json <<EOF
{
  "client_name": "${ENV_ID}",
  "environment": "ephemeral",
  "tenant_id": "${ENV_ID}",
  "aws_region": "us-east-1",
  "expected_account_id": "134051052096",
  "domain_name": "jetscale.ai",
  "terraform_s3_bucket": "jetscale-terraform-state",
  "cluster_name": "${ENV_ID}",
  "kubernetes_namespace": "${ENV_ID}",
  "vpc_cidr": "${VPC_CIDR}",
  "create_dns_records": false,
  "enable_alb_controller": true,
  "enable_external_dns": true,
  "dns_authority_role_arn": "arn:aws:iam::081373342681:role/jetscale-external-dns-dns-authority",
  "acm_certificate_domain": "*.jetscale.ai",
  "enable_deletion_protection": false,
  "enable_nat_gateway": true,
  "create_nat_dns_record": false,
  "tags": {
    "jetscale.env_id": "${ENV_ID}",
    "jetscale.lifecycle": "ephemeral",
    "jetscale.created_at": "${TIMESTAMP}",
    "jetscale.owner": "${GITHUB_ACTOR:-unknown}"
  }
}
EOF
