#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${DESTROY_MODE:?DESTROY_MODE is required}" # "destroy" or "fallback"

if [[ "${DESTROY_MODE}" == "destroy" ]]; then
  terraform init \
    -backend-config="bucket=jetscale-terraform-state" \
    -backend-config="key=ephemeral/${ENV_ID}/terraform.tfstate" \
    -backend-config="region=us-east-1"

  terraform destroy -auto-approve
  exit 0
fi

if [[ "${DESTROY_MODE}" == "fallback" ]]; then
  test -x ./scripts/ephemeral-cleanup.sh
  echo "⚠️ Terraform Destroy failed. Invoking shared cleanup script..."
  ./scripts/ephemeral-cleanup.sh "fallback" "${ENV_ID}" "us-east-1" "134051052096"
  exit 0
fi

echo "::error::Unknown DESTROY_MODE=${DESTROY_MODE}"
exit 1
