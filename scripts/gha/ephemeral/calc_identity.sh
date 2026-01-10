#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

# Optional/env-provided inputs from the workflow:
# INPUTS_ACTION, INPUTS_ENV_ID, GITHUB_EVENT_LABEL_NAME, PR_NUMBER (for PR events),
# GITHUB_HEAD_REF, GITHUB_REF_NAME, GH_TOKEN

PR_NUMBER_ENV="${PR_NUMBER:-}"
ENV_ID="${INPUTS_ENV_ID:-}"

if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
  if [[ -z "${PR_NUMBER_ENV}" ]]; then
    echo "::error::PR number not provided for pull_request event"
    exit 1
  fi
  PR_NUMBER_RESOLVED="${PR_NUMBER_ENV}"
else
  if [[ -n "${ENV_ID}" ]]; then
    if ! echo "${ENV_ID}" | grep -Eq '^pr-[0-9]+$'; then
      echo "::error::inputs.env_id must be like pr-123"
      exit 1
    fi
    PR_NUMBER_RESOLVED="${ENV_ID#pr-}"
  else
    echo "🔍 Manual Dispatch. Resolving PR for commit ${GITHUB_SHA}..."
    STATE_FILTER=""
    if [[ "${INPUTS_ACTION:-deploy}" != "destroy" ]]; then
      STATE_FILTER='| select(.state=="open")'
    fi
    PR_NUMBER_RESOLVED="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" \
      --jq ".[] ${STATE_FILTER} | .number" | head -n 1)"
    if [[ -z "${PR_NUMBER_RESOLVED}" ]]; then
      echo "::error::❌ No matching PR found for this commit. Provide inputs.env_id to run deterministically."
      exit 1
    fi
    echo "✅ Resolved to PR #${PR_NUMBER_RESOLVED}"
  fi
fi

if [[ -z "${ENV_ID}" ]]; then
  ENV_ID="pr-${PR_NUMBER_RESOLVED}"
fi

REF_NAME="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
SLUG="$(echo "${REF_NAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/^-//;s/-$//' | cut -c1-25)"
SLUG=${SLUG:-branch}
HOST="${ENV_ID}-${SLUG}-unstable.jetscale.ai"

{
  echo "PR_NUMBER=${PR_NUMBER_RESOLVED}"
  echo "ENV_ID=${ENV_ID}"
  echo "PUBLIC_HOST=${HOST}"
  echo "TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
} >>"${GITHUB_ENV}"

{
  echo "env_id=${ENV_ID}"
  echo "public_host=${HOST}"
} >>"${GITHUB_OUTPUT}"
