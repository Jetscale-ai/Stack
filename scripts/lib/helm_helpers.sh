#!/usr/bin/env bash
#
# Shared Helm helpers for Stack scripts.
#
# Design goals:
# - Single canonical values ordering to avoid "preview != live" drift.
# - Backward-compatible overrides via environment variables for one-off debugging.
#
# Precedence (highest wins):
#   envs/<cloud>.yaml → envs/<type>/default.yaml → envs/<type>/<client>.yaml
#

# helm_build_values_args <out_array_name> <env_type> <client_name> [cloud]
#
# Populates an array variable (by name) with `--values` arguments in canonical precedence order.
#
# Overrides:
# - VALUES_FILE: if set, use a single values file (legacy escape hatch).
# - VALUES_CLOUD / VALUES_ENV_DEFAULT / VALUES_ENV: override computed file paths.
helm_build_values_args() {
  local out_array_name="${1:-}"
  local env_type="${2:-}"
  local client_name="${3:-}"
  local cloud="${4:-${CLOUD:-aws}}"

  if [[ -z "${out_array_name}" || -z "${env_type}" || -z "${client_name}" ]]; then
    echo "::error::helm_build_values_args usage: helm_build_values_args <out_array_name> <env_type> <client_name> [cloud]" >&2
    return 2
  fi

  local -a args=()

  if [[ -n "${VALUES_FILE:-}" ]]; then
    if [[ ! -f "${VALUES_FILE}" ]]; then
      echo "::error::VALUES_FILE not found: ${VALUES_FILE}" >&2
      return 1
    fi
    args+=(--values "${VALUES_FILE}")
  else
    local cloud_file default_file client_file
    cloud_file="${VALUES_CLOUD:-envs/${cloud}.yaml}"
    default_file="${VALUES_ENV_DEFAULT:-envs/${env_type}/default.yaml}"
    client_file="${VALUES_ENV:-envs/${env_type}/${client_name}.yaml}"

    if [[ ! -f "${cloud_file}" ]]; then
      echo "::error::Missing cloud values file: ${cloud_file}" >&2
      return 1
    fi
    args+=(--values "${cloud_file}")

    if [[ -f "${default_file}" ]]; then
      args+=(--values "${default_file}")
    fi

    if [[ ! -f "${client_file}" ]]; then
      echo "::error::Missing env/client values file: ${client_file}" >&2
      return 1
    fi
    args+=(--values "${client_file}")
  fi

  # Bash nameref: assign by output variable name.
  # shellcheck disable=SC2178
  local -n out="${out_array_name}"
  # shellcheck disable=SC2034  # Used via nameref
  out=("${args[@]}")
}
