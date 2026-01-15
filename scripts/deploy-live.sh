#!/usr/bin/env bash
set -euo pipefail

# ✅ Justified Action: Helm-only Live deploy entrypoint
#
# Goal: Provide a deterministic manual deploy for Live that matches future ArgoCD behavior.
# Invariants: Prudence, Clarity, Concord

NAMESPACE="${NAMESPACE:-jetscale-prod}"
RELEASE="${RELEASE:-jetscale}"
CHART_PATH="${CHART_PATH:-charts/jetscale}"

# Values inheritance (recommended):
# - envs/aws.yaml (cloud)
# - envs/live/default.yaml (env defaults)
# - envs/live/console.yaml (deployment-specific)
#
# Legacy override:
# - VALUES_FILE=<single values file>
VALUES_FILE="${VALUES_FILE:-}"
VALUES_CLOUD="${VALUES_CLOUD:-envs/aws.yaml}"
VALUES_ENV_DEFAULT="${VALUES_ENV_DEFAULT:-envs/live/default.yaml}"
VALUES_ENV="${VALUES_ENV:-envs/live/console.yaml}"

echo "[deploy-live] helm dependency build ${CHART_PATH}"
helm dependency build "${CHART_PATH}"

if [[ -n "${VALUES_FILE}" ]]; then
  VALUES_ARGS=(--values "${VALUES_FILE}")
else
  VALUES_ARGS=(--values "${VALUES_CLOUD}")
  if [[ -f "${VALUES_ENV_DEFAULT}" ]]; then
    VALUES_ARGS+=(--values "${VALUES_ENV_DEFAULT}")
  fi
  VALUES_ARGS+=(--values "${VALUES_ENV}")
fi

echo "[deploy-live] helm upgrade --install ${RELEASE} ${CHART_PATH} -n ${NAMESPACE} ${VALUES_ARGS[*]}"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  "${VALUES_ARGS[@]}"

echo "[deploy-live] done"


