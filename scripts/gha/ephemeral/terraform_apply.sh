#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

REGION="${AWS_REGION:-us-east-1}"

# Ensure all kubeconfig-reading tools/providers use the same config path.
export KUBECONFIG="${HOME}/.kube/config"

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
if aws s3 ls "s3://${BUCKET}/${STATE_KEY}" >/dev/null 2>&1; then
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
fi

# If NAT is enabled, bootstrap egress first so Helm releases can pull public images.
ENABLE_NAT="$(python -c "import json; data = json.load(open('ephemeral.auto.tfvars.json')); print('true' if data.get('enable_nat_gateway') else 'false')" 2>/dev/null || echo "false")"
if [[ "${ENABLE_NAT}" == "true" ]]; then
  echo "::group::Bootstrap: NAT gateway + private egress routes"
  echo "enable_nat_gateway=true → applying NAT + private route changes first"
  terraform apply -auto-approve -refresh=false \
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

# Wait explicitly for RBAC to propagate.
if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  echo "::group::Wait: Kubernetes RBAC ready for Terraform (aws-auth / namespace / serviceaccounts)"
  aws eks update-kubeconfig --name "${ENV_ID}" --region "${REGION}" || true

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"
  echo "caller=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
  echo "principal_arn=${PRINCIPAL_ARN}"
  echo "kubectl_context=$(kubectl config current-context 2>/dev/null || true)"
  echo "kubectl_version=$(kubectl version --client --short 2>/dev/null || true)"
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
      echo "## Ephemeral: Kubernetes RBAC baseline"
      echo ""
      echo "- env_id: \`${ENV_ID}\`"
      echo "- caller: \`$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)\`"
      echo "- principal_arn: \`${PRINCIPAL_ARN}\`"
      echo "- kubectl_context: \`$(kubectl config current-context 2>/dev/null || true)\`"
      echo "- kubectl_version: \`$(kubectl version --client --short 2>/dev/null || true)\`"
      echo "- eks_auth_mode: \`$(aws eks describe-cluster --name \"${ENV_ID}\" --region ${REGION} --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || true)\`"
      echo ""
      echo "### kubectl auth can-i"
      echo ""
      echo '```text'
      can_i_status_line || true
      echo '```'
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
  out="$(terraform import -input=false -no-color "${addr}" "${id}" 2>&1)"
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

import_helm_release 'helm_release.aws_load_balancer_controller[0]' 'kube-system/aws-load-balancer-controller'
import_helm_release 'helm_release.external_dns[0]' 'kube-system/external-dns'
import_helm_release 'helm_release.external_secrets[0]' 'external-secrets-system/external-secrets'

PLANFILE="/tmp/tf.plan"

run_plan() {
  local label="$1"
  echo "::group::Terraform Plan (${label})"
  set +e
  terraform plan -out="${PLANFILE}" -input=false -no-color 2>&1 | tee /tmp/tf-plan.log
  local rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  return "${rc}"
}

run_apply_plan() {
  local label="$1"
  echo "::group::Terraform Apply (${label})"
  set +e
  terraform apply -input=false -auto-approve -no-color "${PLANFILE}" 2>&1 | tee /tmp/tf-apply.log
  local rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  return "${rc}"
}

run_plan "initial"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  echo "::error::Terraform plan failed. See /tmp/tf-plan.log output above for details."
  python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" /tmp/tf-plan.log || true
  exit "${rc}"
fi

run_apply_plan "initial"
rc=$?

if [[ "${rc}" -ne 0 ]]; then
  if grep -Eq "Error acquiring the state lock|PreconditionFailed" /tmp/tf-apply.log; then
    clean_log="$(sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' /tmp/tf-apply.log | tr -d '\r')"
    lock_id="$(echo "${clean_log}" | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n 1 || true)"
    echo "::group::Diagnostics: Terraform state lock"
    echo "Terraform failed to acquire the state lock."
    echo "parsed_lock_id=${lock_id:-unknown}"
    if [[ -n "${lock_id:-}" ]]; then
      terraform force-unlock -force "${lock_id}" || true
    else
      echo "::error::Could not parse lock ID. Re-run the job to retry."
      echo "${clean_log}" | sed -n '/Lock Info:/,/^$/p' | head -n 60 || true
      exit "${rc}"
    fi
    echo "::endgroup::"

    echo "🔁 Retrying once after clearing lock..."
    run_plan "after-force-unlock"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "::error::Terraform plan failed after force-unlock. See /tmp/tf-plan.log output above for details."
      python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" /tmp/tf-plan.log || true
      exit "${rc}"
    fi
    run_apply_plan "after-force-unlock"
    rc=$?
  fi
fi

if [[ "${rc}" -ne 0 ]]; then
  if grep -Eq "helm_release\\.aws_load_balancer_controller|aws-load-balancer-controller|context deadline exceeded|cannot re-use a name that is still in use" /tmp/tf-apply.log; then
    echo "::group::Wait: aws-load-balancer-controller readiness"
    aws eks update-kubeconfig --name "${ENV_ID}" --region "${REGION}" || true
    kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=10m || true
    kubectl -n kube-system get pods -o wide || true
    echo "::endgroup::"

    echo "🔁 Retrying once after waiting for aws-load-balancer-controller..."
    run_plan "after-alb-wait"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "::error::Terraform plan failed after ALB wait. See /tmp/tf-plan.log output above for details."
      python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" /tmp/tf-plan.log || true
      exit "${rc}"
    fi
    run_apply_plan "after-alb-wait"
    rc=$?
  fi
fi

if [[ "${rc}" -ne 0 ]]; then
  echo "::error::Terraform apply failed. See /tmp/tf-apply.log output above for details."
  python3 "${GITHUB_WORKSPACE}/scripts/gha/ephemeral/extract_tf_errors.py" /tmp/tf-apply.log || true
  exit "${rc}"
fi

CLUSTER_NAME="$(terraform output -raw cluster_name)"
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "::error::Terraform did not output a cluster_name"
  exit 1
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}" >> "${GITHUB_ENV}"
