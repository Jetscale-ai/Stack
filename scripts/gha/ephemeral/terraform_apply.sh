#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

terraform init \
  -backend-config="bucket=jetscale-terraform-state" \
  -backend-config="key=ephemeral/${ENV_ID}/terraform.tfstate" \
  -backend-config="region=us-east-1"

if aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 >/dev/null 2>&1; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"
  aws eks create-access-entry --cluster-name "${ENV_ID}" --region us-east-1 --principal-arn "${PRINCIPAL_ARN}" >/dev/null 2>&1 || true
  aws eks associate-access-policy --cluster-name "${ENV_ID}" --region us-east-1 --principal-arn "${PRINCIPAL_ARN}" --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster >/dev/null 2>&1 || true
fi

BUCKET="jetscale-terraform-state"
STATE_KEY="ephemeral/${ENV_ID}/terraform.tfstate"
STATE_PATH="/tmp/${ENV_ID}.tfstate.json"
STATE_EXISTS="false"
if aws s3 ls "s3://${BUCKET}/${STATE_KEY}" >/dev/null 2>&1; then
  STATE_EXISTS="true"
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

  VPC_ID="$(terraform state show -no-color aws_vpc.main 2>/dev/null | grep -E '^\s*id\s*=' | awk -F'=' '{print $2}' | tr -d ' "' || true)"
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

max_attempts=3
rc=0
for attempt in $(seq 1 "${max_attempts}"); do
  echo "::group::Terraform Apply (attempt ${attempt}/${max_attempts})"
  set +e
  terraform apply -auto-approve 2>&1 | tee /tmp/tf-apply.log
  rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"

  if [[ "${rc}" -eq 0 ]]; then
    break
  fi

  if grep -Eq "Error acquiring the state lock|PreconditionFailed" /tmp/tf-apply.log; then
    clean_log="$(sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' /tmp/tf-apply.log | tr -d '\r')"
    lock_id="$(echo "${clean_log}" | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n 1 || true)"
    echo "::group::Diagnostics: Terraform state lock"
    echo "Terraform failed to acquire the state lock."
    echo "parsed_lock_id=${lock_id:-unknown}"
    if [[ -n "${lock_id:-}" ]]; then
      terraform force-unlock -force "${lock_id}" || true
    else
      echo "⚠️ Could not parse lock ID; lock block (sanitized):"
      echo "${clean_log}" | sed -n '/Lock Info:/,/^$/p' | head -n 60 || true
    fi
    echo "::endgroup::"
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      sleep_for=$((30 * attempt))
      echo "⏳ Waiting ${sleep_for}s before retry..."
      sleep "${sleep_for}"
      continue
    fi
  fi

  if grep -Eq "helm_release\\.aws_load_balancer_controller|aws-load-balancer-controller|context deadline exceeded|cannot re-use a name that is still in use" /tmp/tf-apply.log; then
    echo "::group::Diagnostics: aws-load-balancer-controller (attempt ${attempt})"
    aws eks update-kubeconfig --name "${ENV_ID}" --region us-east-1 || true
    kubectl get nodes -o wide || true
    kubectl -n kube-system get pods -o wide || true
    kubectl -n kube-system describe deployment aws-load-balancer-controller || true
    kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=200 || true
    kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -n 120 || true
    helm -n kube-system status aws-load-balancer-controller || true
    helm -n kube-system history aws-load-balancer-controller || true

    echo "::group::Network egress diagnostics (NAT/Routes)"
    VPC_ID_DIAG="$(aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
    SUBNET_IDS="$(aws eks describe-cluster --name "${ENV_ID}" --region us-east-1 --query 'cluster.resourcesVpcConfig.subnetIds' --output text 2>/dev/null || true)"
    echo "vpc_id=${VPC_ID_DIAG:-unknown}"
    echo "cluster_subnets=${SUBNET_IDS:-unknown}"
    for s in ${SUBNET_IDS}; do
      [[ -z "${s}" ]] && continue
      echo "--- subnet: ${s}"
      RT_IDS="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${s}" \
        --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)"
      if [[ -z "${RT_IDS}" ]]; then
        echo "no route table association found for subnet"
        continue
      fi
      for rt in ${RT_IDS}; do
        echo "route_table: ${rt}"
        aws ec2 describe-route-tables --route-table-ids "${rt}" \
          --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' \
          --output json 2>/dev/null || true
      done
    done
    echo "::endgroup::"
    echo "::endgroup::"

    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      sleep_for=$((60 * attempt))
      echo "⏳ Waiting ${sleep_for}s before retry..."
      sleep "${sleep_for}"
      continue
    fi
  fi

  exit "${rc}"
done

if [[ "${rc}" -ne 0 ]]; then
  exit "${rc}"
fi

CLUSTER_NAME=$(terraform output -raw cluster_name)
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "::error::Terraform did not output a cluster_name"
  exit 1
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}" >> "${GITHUB_ENV}"
