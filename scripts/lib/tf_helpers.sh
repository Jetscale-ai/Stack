#!/usr/bin/env bash
#
# Shared Terraform helpers for Stack scripts.
#
# Goals:
# - Centralize common retry patterns (state lock contention, known transient webhook timeouts).
# - Keep caller scripts readable by extracting noisy boilerplate.
#

# Set by terraform_apply_with_retry on failure: "plan" or "apply".
TF_FAILURE_STAGE=""

_tf_strip_ansi() {
  # Strip ANSI escape sequences and Windows CRs from a string.
  sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -d '\r'
}

_tf_parse_lock_id() {
  # Extract Terraform lock UUID from text (best-effort).
  grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n 1
}

# terraform_import_with_lock_retry <addr> <import_id> [terraform_import_options...]
#
# Retries once if the import fails due to a stale S3 lock.
terraform_import_with_lock_retry() {
  local addr="${1:?addr is required}"
  local import_id="${2:?import_id is required}"
  shift 2
  local -a tf_opts=("$@")

  echo "::group::Terraform Import: ${addr}"
  echo "import_id=${import_id}"

  set +e
  local out rc
  out="$(terraform import -input=false -no-color "${tf_opts[@]}" "${addr}" "${import_id}" 2>&1)"
  rc=$?
  set -e
  echo "${out}"

  if [[ "${rc}" -eq 0 ]]; then
    echo "::endgroup::"
    return 0
  fi

  if echo "${out}" | grep -Eq "Error acquiring the state lock|PreconditionFailed"; then
    local clean_log lock_id
    clean_log="$(echo "${out}" | _tf_strip_ansi)"
    lock_id="$(echo "${clean_log}" | _tf_parse_lock_id || true)"
    echo "lock_error=true"
    echo "parsed_lock_id=${lock_id:-unknown}"
    if [[ -n "${lock_id:-}" ]]; then
      echo "🔓 Forcing unlock for stale lock: ${lock_id}"
      terraform force-unlock -force "${lock_id}" || true

      echo "🔁 Retrying terraform import after force-unlock..."
      set +e
      out="$(terraform import -input=false -no-color "${tf_opts[@]}" "${addr}" "${import_id}" 2>&1)"
      rc=$?
      set -e
      echo "${out}"
    fi
  fi

  echo "::endgroup::"
  return "${rc}"
}

_tf_run_plan_to_file() {
  local label="${1:?label is required}"
  local planfile="${2:?planfile is required}"
  local plan_log="${3:?plan_log is required}"
  shift 3
  local -a tf_var_args=("$@")

  echo "::group::Terraform Plan (${label})"
  set +e
  terraform plan -out="${planfile}" -input=false -no-color "${tf_var_args[@]}" 2>&1 | tee "${plan_log}"
  local rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  return "${rc}"
}

_tf_apply_planfile_to_log() {
  local label="${1:?label is required}"
  local planfile="${2:?planfile is required}"
  local apply_log="${3:?apply_log is required}"

  echo "::group::Terraform Apply (${label})"
  set +e
  terraform apply -input=false -auto-approve -no-color "${planfile}" 2>&1 | tee "${apply_log}"
  local rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  return "${rc}"
}

_tf_wait_for_alb_controller_best_effort() {
  local env_id="${1:?env_id is required}"
  local region="${2:?region is required}"
  local kubeconfig_path="${3:-${KUBECONFIG:-${HOME}/.kube/config}}"

  echo "::group::Wait: aws-load-balancer-controller readiness"
  if command -v aws >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "${env_id}" --region "${region}" --kubeconfig "${kubeconfig_path}" >/dev/null 2>&1 || true
  fi
  if command -v kubectl >/dev/null 2>&1; then
    kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=10m || true
    kubectl -n kube-system get pods -o wide || true
  fi
  echo "::endgroup::"
}

# terraform_apply_with_retry <env_id> <region> <planfile> <plan_log> <apply_log> [terraform_plan_var_args...]
#
# Implements two known transient retry paths:
# - State lock contention: force-unlock and retry once
# - AWS Load Balancer Controller webhook timeouts: wait for controller readiness and retry once
terraform_apply_with_retry() {
  local env_id="${1:?env_id is required}"
  local region="${2:?region is required}"
  local planfile="${3:?planfile is required}"
  local plan_log="${4:?plan_log is required}"
  local apply_log="${5:?apply_log is required}"
  shift 5
  local -a tf_var_args=("$@")

  TF_FAILURE_STAGE=""

  _tf_run_plan_to_file "initial" "${planfile}" "${plan_log}" "${tf_var_args[@]}"
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    TF_FAILURE_STAGE="plan"
    return "${rc}"
  fi

  _tf_apply_planfile_to_log "initial" "${planfile}" "${apply_log}"
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi

  if grep -Eq "Error acquiring the state lock|PreconditionFailed" "${apply_log}"; then
    local clean_log lock_id
    clean_log="$(cat "${apply_log}" | _tf_strip_ansi)"
    lock_id="$(echo "${clean_log}" | _tf_parse_lock_id || true)"
    echo "::group::Diagnostics: Terraform state lock"
    echo "Terraform failed to acquire the state lock."
    echo "parsed_lock_id=${lock_id:-unknown}"
    if [[ -n "${lock_id:-}" ]]; then
      terraform force-unlock -force "${lock_id}" || true
    else
      echo "::error::Could not parse lock ID. Re-run to retry."
      echo "${clean_log}" | sed -n '/Lock Info:/,/^$/p' | head -n 60 || true
      echo "::endgroup::"
      TF_FAILURE_STAGE="apply"
      return "${rc}"
    fi
    echo "::endgroup::"

    echo "🔁 Retrying once after clearing lock..."
    _tf_run_plan_to_file "after-force-unlock" "${planfile}" "${plan_log}" "${tf_var_args[@]}"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      TF_FAILURE_STAGE="plan"
      return "${rc}"
    fi
    _tf_apply_planfile_to_log "after-force-unlock" "${planfile}" "${apply_log}"
    rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi
  fi

  if grep -Eq "helm_release\\.aws_load_balancer_controller|aws-load-balancer-controller|context deadline exceeded|cannot re-use a name that is still in use" "${apply_log}"; then
    _tf_wait_for_alb_controller_best_effort "${env_id}" "${region}"

    echo "🔁 Retrying once after waiting for aws-load-balancer-controller..."
    _tf_run_plan_to_file "after-alb-wait" "${planfile}" "${plan_log}" "${tf_var_args[@]}"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      TF_FAILURE_STAGE="plan"
      return "${rc}"
    fi
    _tf_apply_planfile_to_log "after-alb-wait" "${planfile}" "${apply_log}"
    rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi
  fi

  # shellcheck disable=SC2034  # Used by sourcing scripts
  TF_FAILURE_STAGE="apply"
  return "${rc}"
}
