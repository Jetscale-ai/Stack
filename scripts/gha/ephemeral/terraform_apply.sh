#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

REGION="${AWS_REGION:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/tf_helpers.sh"

# Ensure all kubeconfig-reading tools/providers use the same config path.
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# kubectl_client_version prints a stable client version string across kubectl versions.
kubectl_client_version() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  local v=""
  v="$(kubectl version --client=true -o yaml 2>/dev/null | awk '/gitVersion:/ {print $2; exit}' || true)"
  if [[ -z "${v}" ]]; then
    v="$(kubectl version --client=true 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //; s/ $//')"
  fi
  echo "${v}"
}

fmt_code_or_unavailable() {
  local v="${1:-}"
  if [[ -z "${v}" || "${v}" == "None" || "${v}" == "null" ]]; then
    echo "⚠️ _Unavailable_"
  else
    echo "\`${v}\`"
  fi
}

# Optional: if Jetscale-IaC declares `variable "kubeconfig_path"`, pass it explicitly.
# This keeps Stack scripts forward-compatible without breaking older IaC revisions.
TF_VAR_ARGS=()
if grep -R --no-messages -Eq 'variable[[:space:]]+"kubeconfig_path"' --include='*.tf' --include='*.tf.json' .; then
  TF_VAR_ARGS+=(-var="kubeconfig_path=${KUBECONFIG}")
  export TF_VAR_kubeconfig_path="${KUBECONFIG}"
  echo "terraform_var_kubeconfig_path=${KUBECONFIG}"
else
  echo "terraform_var_kubeconfig_path=absent (using legacy provider config)"
fi

ensure_kubeconfig_required() {
  # Terraform's kubernetes/helm providers will fail with:
  #   "Kubernetes cluster unreachable: invalid configuration: no configuration has been provided"
  # unless a kubeconfig file exists and points at the cluster.
  mkdir -p "${HOME}/.kube"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "::error::kubectl is not available on PATH; cannot run Helm/Kubernetes provider operations."
    exit 1
  fi

  # At points we call this, the cluster is expected to exist.
  if ! aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
    echo "::error::EKS cluster ${ENV_ID} not found yet; cannot run Helm/Kubernetes provider operations."
    exit 1
  fi

  # If a previous step left a placeholder kubeconfig (non-empty but invalid), remove it.
  rm -f "${KUBECONFIG}"

  # This MUST succeed; otherwise Helm/Kubernetes providers cannot talk to the cluster.
  aws eks update-kubeconfig --name "${ENV_ID}" --region "${REGION}" --kubeconfig "${KUBECONFIG}"

  if [[ ! -s "${KUBECONFIG}" ]]; then
    echo "::error::kubeconfig is missing/empty at ${KUBECONFIG}. Helm/Kubernetes providers will be unable to connect."
    echo "caller=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" --query 'cluster.status' --output text 2>/dev/null || true
    exit 1
  fi

  # Validate kubeconfig is actually usable (non-empty current-context).
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "${ctx}" ]]; then
    echo "::error::kubeconfig at ${KUBECONFIG} is present but has no current-context; Helm/Kubernetes providers will be unable to connect."
    echo "caller=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    echo "kubectl_version=$(kubectl_client_version 2>/dev/null || true)"
    echo "::group::kubeconfig (redacted-ish)"
    sed -n '1,120p' "${KUBECONFIG}" || true
    echo "::endgroup::"
    exit 1
  fi
}

terraform init \
  -backend-config="bucket=jetscale-terraform-state" \
  -backend-config="key=ephemeral/${ENV_ID}/terraform.tfstate" \
  -backend-config="region=${REGION}"

# Best-effort: ensure terraform runner can talk to the Kubernetes API (prevents refresh Unauthorized).
if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"
  aws eks create-access-entry --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" >/dev/null 2>&1 || true
  aws eks associate-access-policy --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster >/dev/null 2>&1 || true
fi

# ✅ Justified Action: Prevent destructive replacement on reruns
BUCKET="jetscale-terraform-state"
STATE_KEY="ephemeral/${ENV_ID}/terraform.tfstate"
STATE_PATH="/tmp/${ENV_ID}.tfstate.json"
# IMPORTANT: `aws s3 ls s3://bucket/key` can exit 0 even if the key doesn't exist.
# Use an exact HEAD check so we don't fail later with a 404 (HeadObject).
set +e
aws s3api head-object --bucket "${BUCKET}" --key "${STATE_KEY}" >/dev/null 2>&1
STATE_EXISTS_RC=$?
set -e
if [[ "${STATE_EXISTS_RC}" -eq 0 ]]; then
  echo "🔒 State exists for ${ENV_ID}; reusing VPC CIDR from state to prevent replacement."
  aws s3 cp "s3://${BUCKET}/${STATE_KEY}" "${STATE_PATH}" >/dev/null
  STATE_VPC_CIDR="$(jq -r '
    .resources[]
    | select(.type=="aws_vpc" and .name=="main")
    | .instances[0].attributes.cidr_block
    ' "${STATE_PATH}" 2>/dev/null || true)"
  VARS_VPC_CIDR="$(python -c "import json; print(json.load(open('ephemeral.auto.tfvars.json')).get('vpc_cidr',''))" 2>/dev/null || true)"

  if [[ -z "${STATE_VPC_CIDR:-}" || "${STATE_VPC_CIDR}" == "null" ]]; then
    echo "::error::State exists but could not determine aws_vpc.main.cidr_block from ${STATE_KEY}. Refusing to proceed."
    exit 1
  fi
  if [[ -z "${VARS_VPC_CIDR:-}" ]]; then
    echo "::error::ephemeral.auto.tfvars.json is missing vpc_cidr. Refusing to proceed."
    exit 1
  fi
  if [[ "${STATE_VPC_CIDR}" != "${VARS_VPC_CIDR}" ]]; then
    echo "::error::Refusing to proceed: vpc_cidr mismatch for ${ENV_ID} (state=${STATE_VPC_CIDR}, vars=${VARS_VPC_CIDR}). This would force VPC replacement."
    exit 1
  fi
else
  echo "ℹ️ No existing state object at s3://${BUCKET}/${STATE_KEY}; proceeding as a fresh env."
fi

# If NAT is enabled, bootstrap egress first so Helm releases can pull public images.
ENABLE_NAT="$(python -c "import json; data = json.load(open('ephemeral.auto.tfvars.json')); print('true' if data.get('enable_nat_gateway') else 'false')" 2>/dev/null || echo "false")"
if [[ "${ENABLE_NAT}" == "true" ]]; then
  echo "::group::Bootstrap: NAT gateway + private egress routes"
  echo "enable_nat_gateway=true → applying NAT + private route changes first"
  terraform apply -auto-approve -refresh=false "${TF_VAR_ARGS[@]}" \
    -target=aws_vpc.main \
    -target=aws_internet_gateway.main \
    -target=aws_subnet.public \
    -target=aws_route_table.public \
    -target=aws_route_table_association.public \
    -target=aws_eip.nat[0] \
    -target=aws_nat_gateway.main[0] \
    -target=aws_route_table.private \
    -target=aws_route_table_association.private

  # Wait briefly for NAT to become available (best-effort) so pods can start pulling images.
  VPC_ID="$(terraform state show -no-color aws_vpc.main 2>/dev/null | grep -E '^\s*id\s*=' | awk -F'=' '{print $2}' | tr -d ' \"' || true)"
  if [[ -n "${VPC_ID}" ]]; then
    echo "vpc_id=${VPC_ID}"
    for i in $(seq 1 30); do
      STATE="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=pending,available" --query 'NatGateways[0].State' --output text 2>/dev/null || true)"
      if [[ "${STATE}" == "available" ]]; then
        echo "✅ NAT gateway is available"
        break
      fi
      echo "⏳ Waiting for NAT gateway... (state=${STATE:-unknown}) [${i}/30]"
      sleep 10
    done
  fi
  echo "::endgroup::"
fi

# -------------------------------------------------------------------
# ✅ Justified Action: Day-0 EKS bootstrap (cluster before kubeconfig-dependent providers)
# -------------------------------------------------------------------
#
# Goal:
# - After "Zombie State" pruning and State Reconciliation, we can legitimately have a VPC in state
#   while the EKS cluster does not yet exist (fresh ephemeral bootstrap).
# - Our ephemeral provider strategy relies on kubeconfig at plan-time (to avoid unknown provider
#   config), so we must create the EKS control plane *before* any Helm/Kubernetes provider operations.
#
# Invariants: Prudence, Vigor, Concord
#
if ! aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  echo "::group::Bootstrap: EKS cluster (Day 0)"

  # EKS may auto-create this log group when control-plane logging is enabled. Create it first to
  # avoid a later "ResourceAlreadyExistsException" during the full apply.
  terraform apply -auto-approve -refresh=false "${TF_VAR_ARGS[@]}" \
    -target=aws_cloudwatch_log_group.eks_cluster

  # Bootstrap the control plane (AWS-only resources; avoids kubeconfig dependency).
  terraform apply -auto-approve -refresh=false "${TF_VAR_ARGS[@]}" \
    -target=aws_eks_cluster.main

  # Best-effort: ensure the runner role has EKS API access (helps avoid transient Unauthorized).
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"
  aws eks create-access-entry --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" >/dev/null 2>&1 || true
  aws eks associate-access-policy --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster >/dev/null 2>&1 || true

  if ! aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
    echo "::error::EKS cluster ${ENV_ID} still not found after bootstrap apply; aborting."
    exit 1
  fi

  echo "::endgroup::"
fi

# Wait explicitly for RBAC to propagate.
if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  echo "::group::Wait: Kubernetes RBAC ready for Terraform (aws-auth / namespace / serviceaccounts)"
  ensure_kubeconfig_required

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"
  echo "caller=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
  echo "principal_arn=${PRINCIPAL_ARN}"
  echo "kubectl_context=$(kubectl config current-context 2>/dev/null || true)"
  echo "kubectl_version=$(kubectl_client_version 2>/dev/null || true)"
  aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" --query 'cluster.accessConfig.authenticationMode' --output text || true
  aws eks describe-access-entry --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" >/dev/null 2>&1 && echo "eks_access_entry=present" || echo "eks_access_entry=absent"
  aws eks list-associated-access-policies --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" >/dev/null 2>&1 && echo "eks_access_policies=list_ok" || echo "eks_access_policies=list_failed"

  can_i_ok() {
    kubectl auth can-i get configmap/aws-auth -n kube-system 2>/dev/null | grep -qi '^yes$' \
      && kubectl auth can-i patch configmap/aws-auth -n kube-system 2>/dev/null | grep -qi '^yes$' \
      && kubectl auth can-i create namespace 2>/dev/null | grep -qi '^yes$' \
      && kubectl auth can-i create serviceaccounts -n kube-system 2>/dev/null | grep -qi '^yes$'
  }

  can_i_status_line() {
    local get_cm patch_cm create_ns create_sa
    get_cm="$(kubectl auth can-i get configmap/aws-auth -n kube-system 2>&1 | tr -d '\r' | tail -n 1)"
    patch_cm="$(kubectl auth can-i patch configmap/aws-auth -n kube-system 2>&1 | tr -d '\r' | tail -n 1)"
    create_ns="$(kubectl auth can-i create namespace 2>&1 | tr -d '\r' | tail -n 1)"
    create_sa="$(kubectl auth can-i create serviceaccounts -n kube-system 2>&1 | tr -d '\r' | tail -n 1)"
    echo "get_cm=${get_cm} patch_cm=${patch_cm} create_ns=${create_ns} create_sa=${create_sa}"
  }

  echo "::group::RBAC baseline (kubectl auth can-i)"
  can_i_status_line || true
  echo "::endgroup::"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "<details>"
      echo "<summary>🔐 <strong>Ephemeral Identity &amp; RBAC</strong> (click to expand)</summary>"
      echo ""
      echo "### 🆔 Identity Context"
      echo ""
      kubectl_context="$(kubectl config current-context 2>/dev/null || true)"
      kubectl_v="$(kubectl_client_version 2>/dev/null || true)"
      cluster_arn="$(aws eks describe-cluster --name \"${ENV_ID}\" --region ${REGION} --query 'cluster.arn' --output text 2>/dev/null || true)"
      eks_auth_mode="$(aws eks describe-cluster --name \"${ENV_ID}\" --region ${REGION} --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || true)"
      if [[ -z "${cluster_arn}" || "${cluster_arn}" == "None" || "${cluster_arn}" == "null" ]]; then
        cluster_arn="${kubectl_context}"
      fi
      cluster_cell="$(fmt_code_or_unavailable "${cluster_arn}")"
      kubectl_ctx_cell="$(fmt_code_or_unavailable "${kubectl_context}")"
      kubectl_cell="$(fmt_code_or_unavailable "${kubectl_v}")"
      auth_mode_cell="$(fmt_code_or_unavailable "${eks_auth_mode}")"
      echo "| Component | Identity / Resource |"
      echo "| :--- | :--- |"
      echo "| env_id | \`${ENV_ID}\` |"
      echo "| caller | \`$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)\` |"
      echo "| principal_arn | \`${PRINCIPAL_ARN}\` |"
      echo "| cluster | ${cluster_cell} |"
      echo "| kubectl_context | ${kubectl_ctx_cell} |"
      echo "| kubectl | ${kubectl_cell} |"
      echo "| eks_auth_mode | ${auth_mode_cell} |"
      echo ""
      echo "### 🛡️ RBAC Capabilities (kubectl auth can-i)"
      echo ""
      echo '```text'
      can_i_status_line || true
      echo '```'
      echo ""
      echo "</details>"
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  for i in $(seq 1 60); do
    if can_i_ok; then
      echo "✅ RBAC is ready for Terraform (can-i checks passed)"
      break
    fi
    echo "⏳ waiting for RBAC/auth propagation... [${i}/60] $(can_i_status_line)"
    sleep 10
  done

  if ! can_i_ok; then
    echo "::error::Kubernetes RBAC is not ready for Terraform (can-i checks failing). This would cause Terraform 'Unauthorized'."
    echo "caller=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    echo "principal_arn=${PRINCIPAL_ARN}"
    echo "kubectl_context=$(kubectl config current-context 2>/dev/null || true)"

    echo "::group::RBAC diagnostics (kubectl auth can-i)"
    kubectl auth can-i get configmap/aws-auth -n kube-system || true
    kubectl auth can-i patch configmap/aws-auth -n kube-system || true
    kubectl auth can-i create namespace || true
    kubectl auth can-i create serviceaccounts -n kube-system || true
    echo "::endgroup::"

    echo "::group::EKS access entry diagnostics"
    aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" --query 'cluster.accessConfig.authenticationMode' --output text || true
    aws eks describe-access-entry --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" || true
    aws eks list-associated-access-policies --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" || true
    echo "::endgroup::"

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## Ephemeral: RBAC wait timed out"
        echo ""
        echo "Terraform will fail with \`Unauthorized\` until the following become **yes**:"
        echo ""
        echo '```text'
        can_i_status_line || true
        echo '```'
        echo ""
        echo "### EKS access entry (raw)"
        echo ""
        echo '```json'
        aws eks describe-access-entry --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" 2>/dev/null || true
        echo '```'
        echo ""
        echo "### EKS access policies (raw)"
        echo ""
        echo '```json'
        aws eks list-associated-access-policies --cluster-name "${ENV_ID}" --region "${REGION}" --principal-arn "${PRINCIPAL_ARN}" 2>/dev/null || true
        echo '```'
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
    fi

    exit 1
  fi

  echo "::endgroup::"
fi

import_helm_release() {
  local addr="$1"
  local id="$2"

  if terraform state list "${addr}" >/dev/null 2>&1; then
    echo "✅ already in state: ${addr}"
    return 0
  fi

  echo "::group::Terraform Import (helm): ${addr}"
  echo "import_id=${id}"
  set +e
  out="$(terraform import -input=false -no-color "${TF_VAR_ARGS[@]}" "${addr}" "${id}" 2>&1)"
  rc=$?
  set -e
  echo "${out}"
  echo "::endgroup::"

  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi

  if echo "${out}" | grep -Eqi "Cannot import non-existent remote object|release: not found"; then
    echo "⚠️ import skipped (release not found): ${addr} (${id})"
    return 0
  fi

  return "${rc}"
}

ensure_kubeconfig_required
import_helm_release 'helm_release.aws_load_balancer_controller[0]' 'kube-system/aws-load-balancer-controller'
import_helm_release 'helm_release.external_dns[0]' 'kube-system/external-dns'
import_helm_release 'helm_release.external_secrets[0]' 'external-secrets-system/external-secrets'

PLANFILE="/tmp/tf.plan"
PLAN_LOG="/tmp/tf-plan.log"
APPLY_LOG="/tmp/tf-apply.log"

terraform_apply_with_retry "${ENV_ID}" "${REGION}" "${PLANFILE}" "${PLAN_LOG}" "${APPLY_LOG}" "${TF_VAR_ARGS[@]}"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  if [[ "${TF_FAILURE_STAGE}" == "plan" ]]; then
    echo "::error::Terraform plan failed. See ${PLAN_LOG} output above for details."
    python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" "${PLAN_LOG}" || true
  else
    echo "::error::Terraform apply failed. See ${APPLY_LOG} output above for details."
    python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" "${APPLY_LOG}" || true
  fi
  exit "${rc}"
fi

CLUSTER_NAME="$(terraform output -raw cluster_name)"
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "::error::Terraform did not output a cluster_name"
  exit 1
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}" >> "${GITHUB_ENV}"
