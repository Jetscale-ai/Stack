#!/usr/bin/env bash
set -euo pipefail

# ✅ Justified Action: Helm-only Live deploy entrypoint
#
# Goal: Provide a deterministic manual deploy for Live that matches future ArgoCD behavior.
# Invariants: Prudence, Clarity, Concord

NAMESPACE="${NAMESPACE:-jetscale-prod}"
RELEASE="${RELEASE:-jetscale}"
CHART_PATH="${CHART_PATH:-charts/jetscale}"
VALUES_FILE="${VALUES_FILE:-envs/live/values.yaml}"

echo "[deploy-live] helm dependency build ${CHART_PATH}"
helm dependency build "${CHART_PATH}"

echo "[deploy-live] helm upgrade --install ${RELEASE} ${CHART_PATH} -n ${NAMESPACE} -f ${VALUES_FILE}"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}"

echo "[deploy-live] done"


