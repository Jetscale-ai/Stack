#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"

CLUSTER_NAME="${ENV_ID}"
STATE_KEY="ephemeral/${ENV_ID}/terraform.tfstate"
BUCKET="jetscale-terraform-state"
REGION="us-east-1"

echo "🔍 Checking for Zombie State (Cluster: ${CLUSTER_NAME})..."

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "✅ Cluster exists in AWS. Terraform state is likely valid."
else
  echo "👻 Cluster '${CLUSTER_NAME}' NOT found in AWS."
  if aws s3 ls "s3://${BUCKET}/${STATE_KEY}" >/dev/null 2>&1; then
    echo "⚠️  ORPHANED STATE DETECTED! (Cluster missing, but state exists)"
    echo "💥 Nuking state to prevent provider connection refused errors..."
    aws s3 rm "s3://${BUCKET}/${STATE_KEY}"
    echo "✅ State cleared. Ready for fresh bootstrap."
  else
    echo "✅ No state found. Clean slate."
  fi
fi
