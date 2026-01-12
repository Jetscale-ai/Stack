#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"

echo "🔧 Starting State Reconciliation..."

terraform init \
  -backend-config="bucket=jetscale-terraform-state" \
  -backend-config="key=ephemeral/${ENV_ID}/terraform.tfstate" \
  -backend-config="region=us-east-1"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:jetscale.env_id,Values=${ENV_ID}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
if [[ "${VPC_ID}" != "None" && -n "${VPC_ID}" ]]; then
  if ! terraform state list aws_vpc.main >/dev/null 2>&1; then
    echo "📥 Importing existing VPC: ${VPC_ID}"
    terraform import aws_vpc.main "${VPC_ID}" || echo "⚠️ VPC import failed (ignoring)"
  else
    echo "✅ VPC already in state"
  fi

  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "None")
  if [[ "${IGW_ID}" != "None" && -n "${IGW_ID}" ]]; then
    if ! terraform state list aws_internet_gateway.main >/dev/null 2>&1; then
      echo "📥 Importing IGW: ${IGW_ID}"
      terraform import aws_internet_gateway.main "${IGW_ID}" || echo "⚠️ IGW import failed (ignoring)"
    fi
  fi

  NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "None")
  if [[ "${NAT_ID}" != "None" && -n "${NAT_ID}" ]]; then
    if ! terraform state list 'aws_nat_gateway.main[0]' >/dev/null 2>&1; then
      echo "📥 Importing NAT Gateway: ${NAT_ID}"
      terraform import 'aws_nat_gateway.main[0]' "${NAT_ID}" || echo "⚠️ NAT import failed (ignoring)"
    fi
  fi
fi

if aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 >/dev/null 2>&1; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"

  AUTH_MODE="$(aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || true)"
  if [[ "${AUTH_MODE}" == "CONFIG_MAP" ]]; then
    echo "🔐 Updating cluster auth mode to API_AND_CONFIG_MAP (was CONFIG_MAP)..."
    UPDATE_JSON="$(aws eks update-cluster-config --name "${ENV_ID}" --region us-east-1 --access-config authenticationMode=API_AND_CONFIG_MAP --output json || true)"
    UPDATE_ID="$(echo "${UPDATE_JSON:-}" | jq -r '.update.id // empty' 2>/dev/null || true)"
    if [[ -n "${UPDATE_ID:-}" ]]; then
      echo "⏳ Waiting for auth-mode update to complete: ${UPDATE_ID}"
      for i in $(seq 1 60); do
        STATUS="$(aws eks describe-update --name "${ENV_ID}" --region us-east-1 --update-id "${UPDATE_ID}" --query 'update.status' --output text 2>/dev/null || true)"
        if [[ "${STATUS}" == "Successful" ]]; then
          echo "✅ Auth mode update successful"
          break
        fi
        if [[ "${STATUS}" == "Failed" || "${STATUS}" == "Cancelled" ]]; then
          echo "::warning::Auth mode update status=${STATUS} (continuing; access entry may fail)"
          break
        fi
        sleep 10
      done
    fi
  fi

  aws eks create-access-entry \
    --cluster-name "${ENV_ID}" --region us-east-1 \
    --principal-arn "${PRINCIPAL_ARN}" \
    >/dev/null 2>&1 || true

  aws eks associate-access-policy \
    --cluster-name "${ENV_ID}" --region us-east-1 \
    --principal-arn "${PRINCIPAL_ARN}" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    >/dev/null 2>&1 || true

  echo "🔗 Updating kubeconfig..."
  aws eks update-kubeconfig --name "${ENV_ID}" --region us-east-1 || true

  if kubectl get validatingwebhookconfiguration aws-load-balancer-webhook >/dev/null 2>&1; then
    echo "🔥 Deleting zombie ALB validating webhook to prevent deadlock..."
    kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
  fi

  if kubectl get mutatingwebhookconfiguration aws-load-balancer-webhook >/dev/null 2>&1; then
    echo "🔥 Deleting zombie ALB mutating webhook..."
    kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
  fi
fi

LOG_GROUP="/aws/eks/${ENV_ID}/cluster"
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --query "logGroups[?logGroupName==\`${LOG_GROUP}\`].logGroupName" --output text 2>/dev/null | grep -q "${LOG_GROUP}"; then
  if ! terraform state list aws_cloudwatch_log_group.eks_cluster >/dev/null 2>&1; then
    echo "📥 Importing existing Log Group: ${LOG_GROUP}"
    terraform import aws_cloudwatch_log_group.eks_cluster "${LOG_GROUP}" || echo "⚠️ Log group import failed (ignoring)"
  fi
fi

if aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 >/dev/null 2>&1; then
  if kubectl get ns "${ENV_ID}" >/dev/null 2>&1; then
    if ! terraform state list kubernetes_namespace.this >/dev/null 2>&1; then
      echo "📥 Importing existing Namespace: ${ENV_ID}"
      terraform import kubernetes_namespace.this "${ENV_ID}" || echo "⚠️ Namespace import failed (ignoring)"
    fi
  fi
fi

echo "✅ State Reconciliation Complete."
