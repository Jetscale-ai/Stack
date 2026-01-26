#!/usr/bin/env bash
set -euo pipefail

# ✅ Justified Action: Helm-only Live deploy entrypoint
#
# Goal: Provide a deterministic manual deploy for Live that matches future ArgoCD behavior.
# Invariants: Prudence, Clarity, Concord

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/helm_helpers.sh"

# Canonical env inheritance inputs.
ENV_TYPE="${ENV_TYPE:-live}"
CLIENT_NAME="${CLIENT_NAME:-console}"
CLOUD="${CLOUD:-aws}"

# Naming convention (Phase 3.2):
# - canonical (default): namespace=<client>-prod, release=<client>
# - legacy: namespace=jetscale-prod, release=jetscale
LIVE_NAMING_MODE="${LIVE_NAMING_MODE:-canonical}"

NAMESPACE="${NAMESPACE:-}"
RELEASE="${RELEASE:-}"

if [[ -z "${NAMESPACE}" ]]; then
  if [[ "${LIVE_NAMING_MODE}" == "legacy" ]]; then
    NAMESPACE="jetscale-prod"
  else
    NAMESPACE="${CLIENT_NAME}-prod"
  fi
fi

if [[ -z "${RELEASE}" ]]; then
  if [[ "${LIVE_NAMING_MODE}" == "legacy" ]]; then
    RELEASE="jetscale"
  else
    RELEASE="${CLIENT_NAME}"
  fi
fi

CHART_PATH="${CHART_PATH:-charts/jetscale}"

# Values inheritance (recommended):
# - envs/<cloud>.yaml (cloud)
# - envs/<type>/default.yaml (env defaults)
# - envs/<type>/<client>.yaml (deployment-specific)
#
# Legacy override:
# - VALUES_FILE=<single values file>
VALUES_FILE="${VALUES_FILE:-}"
VALUES_CLOUD="${VALUES_CLOUD:-envs/${CLOUD}.yaml}"
VALUES_ENV_DEFAULT="${VALUES_ENV_DEFAULT:-envs/${ENV_TYPE}/default.yaml}"
VALUES_ENV="${VALUES_ENV:-envs/${ENV_TYPE}/${CLIENT_NAME}.yaml}"

echo "[deploy-live] helm dependency build ${CHART_PATH}"
helm dependency build "${CHART_PATH}"

VALUES_ARGS=()
helm_build_values_args VALUES_ARGS "${ENV_TYPE}" "${CLIENT_NAME}" "${CLOUD}"

echo "[deploy-live] helm upgrade --install ${RELEASE} ${CHART_PATH} -n ${NAMESPACE} ${VALUES_ARGS[*]}"
helm upgrade --install "${RELEASE}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  "${VALUES_ARGS[@]}"

echo "[deploy-live] done"
