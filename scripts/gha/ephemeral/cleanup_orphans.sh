#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"

STATE_KEY="ephemeral/${ENV_ID}/terraform.tfstate"
BUCKET="jetscale-terraform-state"

# Only run if state is missing
if aws s3 ls "s3://${BUCKET}/${STATE_KEY}" >/dev/null 2>&1; then
  echo "✅ Terraform state exists. Skipping orphan cleanup."
  exit 0
fi

test -x ./scripts/ephemeral-cleanup.sh
echo "⚠️ No state found. Invoking shared cleanup script to purge orphans..."
./scripts/ephemeral-cleanup.sh "preflight" "${ENV_ID}" "us-east-1" "134051052096"
