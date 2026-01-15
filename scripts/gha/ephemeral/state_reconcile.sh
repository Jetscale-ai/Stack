#!/usr/bin/env bash
set -euo pipefail

: "${ENV_ID:?ENV_ID is required}"

REGION="${AWS_REGION:-us-east-1}"

echo "🔧 Starting State Reconciliation..."

# Ensure kubeconfig exists for provider init (even if we only touch AWS resources here).
KUBECONFIG_PATH="${HOME}/.kube/config"
mkdir -p "${HOME}/.kube"
if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1 || true
fi
if [ ! -s "${KUBECONFIG_PATH}" ]; then
  cat > "${KUBECONFIG_PATH}" <<'EOF'
apiVersion: v1
kind: Config
clusters: []
contexts: []
users: []
current-context: ""
EOF
fi

terraform init \
  -backend-config="bucket=jetscale-terraform-state" \
  -backend-config="key=ephemeral/${ENV_ID}/terraform.tfstate" \
  -backend-config="region=${REGION}"

VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:jetscale.env_id,Values=${ENV_ID}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")"
if [[ "${VPC_ID}" != "None" && -n "${VPC_ID}" ]]; then
  if ! terraform state list aws_vpc.main >/dev/null 2>&1; then
    echo "📥 Importing existing VPC: ${VPC_ID}"
    terraform import aws_vpc.main "${VPC_ID}" || echo "⚠️ VPC import failed (ignoring)"
  else
    echo "✅ VPC already in state"
  fi

  IGW_ID="$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "None")"
  if [[ "${IGW_ID}" != "None" && -n "${IGW_ID}" ]]; then
    if ! terraform state list aws_internet_gateway.main >/dev/null 2>&1; then
      echo "📥 Importing IGW: ${IGW_ID}"
      terraform import aws_internet_gateway.main "${IGW_ID}" || echo "⚠️ IGW import failed (ignoring)"
    fi
  fi

  # Adopt network primitives before targeted bootstrap.
  NAME_PREFIX="${ENV_ID}-ephemeral"
  ENABLE_NAT="$(python -c "import json; data = json.load(open('ephemeral.auto.tfvars.json')); print('true' if data.get('enable_nat_gateway') else 'false')" 2>/dev/null || echo "false")"
  PUBLIC_RT_NAME="${NAME_PREFIX}-public-rt"
  if [[ "${ENABLE_NAT}" == "true" ]]; then
    PRIVATE_RT_NAME="${NAME_PREFIX}-private-rt"
  else
    PRIVATE_RT_NAME="${NAME_PREFIX}-private-rt-isolated"
  fi

  get_route_table_id_by_name() {
    local name_tag="$1"
    aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name_tag}" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None"
  }

  PUBLIC_RT_ID="$(get_route_table_id_by_name "${PUBLIC_RT_NAME}")"
  PRIVATE_RT_ID="$(get_route_table_id_by_name "${PRIVATE_RT_NAME}")"

  import_route_table() {
    local addr="$1"
    local rtb_id="$2"
    if terraform state list "${addr}" >/dev/null 2>&1; then
      echo "✅ already in state: ${addr}"
      return 0
    fi
    if [[ "${rtb_id}" == "None" || -z "${rtb_id}" ]]; then
      echo "⚠️ route table not found (skip import): ${addr}"
      return 0
    fi
    echo "📥 Importing route table: ${addr} -> ${rtb_id}"
    terraform import "${addr}" "${rtb_id}" || echo "⚠️ route table import failed (ignoring)"
  }

  import_route_table 'aws_route_table.public' "${PUBLIC_RT_ID}"
  import_route_table 'aws_route_table.private' "${PRIVATE_RT_ID}"

  AZS="$(aws ec2 describe-availability-zones \
    --filters "Name=opt-in-status,Values=opt-in-not-required" \
    --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null | tr '\t' '\n' | sort | head -n 2 || true)"
  AZ1="$(echo "${AZS}" | sed -n '1p' || true)"
  AZ2="$(echo "${AZS}" | sed -n '2p' || true)"

  if [[ -n "${AZ1:-}" && -n "${AZ2:-}" ]]; then
    import_subnet_by_name() {
      local addr="$1"
      local name_tag="$2"
      local az="$3"
      if terraform state list "${addr}" >/dev/null 2>&1; then
        echo "✅ already in state: ${addr}"
        return 0
      fi
      local subnet_id
      subnet_id="$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name_tag}" "Name=availability-zone,Values=${az}" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")"
      if [[ "${subnet_id}" == "None" || -z "${subnet_id}" ]]; then
        echo "⚠️ subnet not found (skip import): name=${name_tag} az=${az}"
        return 0
      fi
      echo "📥 Importing subnet: ${addr} -> ${subnet_id} (name=${name_tag} az=${az})"
      terraform import "${addr}" "${subnet_id}" || echo "⚠️ subnet import failed (ignoring)"
    }

    get_subnet_id_by_name_az() {
      local name_tag="$1"
      local az="$2"
      aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name_tag}" "Name=availability-zone,Values=${az}" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None"
    }

    import_subnet_by_name 'aws_subnet.public[0]' "${NAME_PREFIX}-public-subnet-1" "${AZ1}"
    import_subnet_by_name 'aws_subnet.public[1]' "${NAME_PREFIX}-public-subnet-2" "${AZ2}"
    import_subnet_by_name 'aws_subnet.private[0]' "${NAME_PREFIX}-private-subnet-1" "${AZ1}"
    import_subnet_by_name 'aws_subnet.private[1]' "${NAME_PREFIX}-private-subnet-2" "${AZ2}"

    PUBLIC_SUBNET_1_ID="$(get_subnet_id_by_name_az "${NAME_PREFIX}-public-subnet-1" "${AZ1}")"
    PUBLIC_SUBNET_2_ID="$(get_subnet_id_by_name_az "${NAME_PREFIX}-public-subnet-2" "${AZ2}")"
    PRIVATE_SUBNET_1_ID="$(get_subnet_id_by_name_az "${NAME_PREFIX}-private-subnet-1" "${AZ1}")"
    PRIVATE_SUBNET_2_ID="$(get_subnet_id_by_name_az "${NAME_PREFIX}-private-subnet-2" "${AZ2}")"

    import_route_table_assoc() {
      local addr="$1"
      local subnet_id="$2"
      local expected_rtb_id="$3"
      if terraform state list "${addr}" >/dev/null 2>&1; then
        echo "✅ already in state: ${addr}"
        return 0
      fi
      if [[ "${subnet_id}" == "None" || -z "${subnet_id}" || "${expected_rtb_id}" == "None" || -z "${expected_rtb_id}" ]]; then
        echo "⚠️ route table association not found (skip import): ${addr}"
        return 0
      fi
      local current_rtb_id
      current_rtb_id="$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=${subnet_id}" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")"
      if [[ "${current_rtb_id}" == "None" || -z "${current_rtb_id}" ]]; then
        echo "ℹ️ no explicit association for ${subnet_id}; Terraform will create it."
        return 0
      fi
      if [[ "${current_rtb_id}" != "${expected_rtb_id}" ]]; then
        echo "⚠️ subnet ${subnet_id} associated to ${current_rtb_id} (expected ${expected_rtb_id}); importing current association for replacement."
      fi
      echo "📥 Importing route table association: ${addr} -> ${subnet_id}/${current_rtb_id}"
      terraform import "${addr}" "${subnet_id}/${current_rtb_id}" || echo "⚠️ route table association import failed (ignoring)"
    }

    import_route_table_assoc 'aws_route_table_association.public[0]' "${PUBLIC_SUBNET_1_ID}" "${PUBLIC_RT_ID}"
    import_route_table_assoc 'aws_route_table_association.public[1]' "${PUBLIC_SUBNET_2_ID}" "${PUBLIC_RT_ID}"
    import_route_table_assoc 'aws_route_table_association.private[0]' "${PRIVATE_SUBNET_1_ID}" "${PRIVATE_RT_ID}"
    import_route_table_assoc 'aws_route_table_association.private[1]' "${PRIVATE_SUBNET_2_ID}" "${PRIVATE_RT_ID}"
  else
    echo "::warning::Could not determine 2 availability zones; skipping subnet/association adoption."
  fi

  # NAT/EIP adoption
  NAT_ID="None"
  NAT_STATE="unknown"
  EIP_ALLOC_ID="None"

  adopt_nat_from_eip_association() {
    # If the EIP is already associated to a NAT Gateway ENI, treat that as "good enough"
    # and adopt the NATGW + EIP into Terraform state rather than waiting for disassociation.
    #
    # This prevents reruns from timing out when the EIP is correctly in-use by the env's NATGW.
    local alloc_id="$1"
    if [[ "${alloc_id}" == "None" || -z "${alloc_id}" ]]; then
      return 1
    fi

    local eni_id assoc_id iface_type desc inferred_nat_id inferred_state
    eni_id="$(aws ec2 describe-addresses --allocation-ids "${alloc_id}" \
      --query 'Addresses[0].NetworkInterfaceId' --output text 2>/dev/null || echo "None")"
    assoc_id="$(aws ec2 describe-addresses --allocation-ids "${alloc_id}" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo "None")"

    if [[ "${eni_id}" == "None" || -z "${eni_id}" ]]; then
      return 1
    fi

    iface_type="$(aws ec2 describe-network-interfaces --network-interface-ids "${eni_id}" \
      --query 'NetworkInterfaces[0].InterfaceType' --output text 2>/dev/null || echo "None")"
    if [[ "${iface_type}" != "nat_gateway" ]]; then
      return 1
    fi

    desc="$(aws ec2 describe-network-interfaces --network-interface-ids "${eni_id}" \
      --query 'NetworkInterfaces[0].Description' --output text 2>/dev/null || echo "")"
    inferred_nat_id="$(echo "${desc}" | grep -oE 'nat-[0-9a-f]+' | head -n 1 || true)"
    if [[ -z "${inferred_nat_id}" ]]; then
      return 1
    fi

    inferred_state="$(aws ec2 describe-nat-gateways --nat-gateway-ids "${inferred_nat_id}" \
      --query 'NatGateways[0].State' --output text 2>/dev/null || echo "unknown")"

    echo "ℹ️ EIP ${alloc_id} is already associated (association=${assoc_id}) to NAT gateway ${inferred_nat_id} (state=${inferred_state}). Adopting instead of waiting for 'free'."
    NAT_ID="${inferred_nat_id}"
    NAT_STATE="${inferred_state}"
    return 0
  }

  wait_for_eip_free() {
    local alloc_id="$1"
    if [[ "${alloc_id}" == "None" || -z "${alloc_id}" ]]; then
      return 0
    fi
    for i in $(seq 1 60); do
      local assoc_id
      assoc_id="$(aws ec2 describe-addresses --allocation-ids "${alloc_id}" \
        --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo "None")"
      if [[ "${assoc_id}" == "None" || "${assoc_id}" == "null" || -z "${assoc_id}" ]]; then
        echo "✅ EIP ${alloc_id} is free"
        return 0
      fi

      # If the association is to a NAT Gateway ENI, do not wait forever for "free" on reruns.
      # Instead, adopt the NATGW and proceed (Terraform will keep the association stable).
      if adopt_nat_from_eip_association "${alloc_id}"; then
        return 0
      fi

      echo "⏳ Waiting for EIP ${alloc_id} to be free (association=${assoc_id}) [${i}/60]"
      sleep 10
    done
    echo "::error::EIP ${alloc_id} is still associated after wait; aborting to avoid NAT create failure."
    exit 1
  }

  if [[ "${ENABLE_NAT}" == "true" ]]; then
    if terraform state list 'aws_eip.nat[0]' >/dev/null 2>&1; then
      EIP_ALLOC_ID="$(terraform state show -no-color 'aws_eip.nat[0]' 2>/dev/null | awk -F'=' '/allocation_id/ {gsub(/^[ \t"]+|[ \t"]+$/, "", $2); print $2; exit}')"
    fi
    if [[ "${EIP_ALLOC_ID}" == "None" || -z "${EIP_ALLOC_ID}" ]]; then
      EIP_ALLOC_ID="$(aws ec2 describe-addresses \
        --filters "Name=tag:Name,Values=${NAME_PREFIX}-nat-eip" "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")"
    fi
    if [[ "${EIP_ALLOC_ID}" != "None" && -n "${EIP_ALLOC_ID}" ]]; then
      NAT_INFO="$(aws ec2 describe-nat-gateways \
        --filter "Name=nat-gateway-address.allocation-id,Values=${EIP_ALLOC_ID}" \
        --query 'NatGateways[0].[NatGatewayId,State]' --output text 2>/dev/null || echo "None")"
      if [[ "${NAT_INFO}" != "None" && -n "${NAT_INFO}" ]]; then
        NAT_ID="$(echo "${NAT_INFO}" | awk '{print $1}')"
        NAT_STATE="$(echo "${NAT_INFO}" | awk '{print $2}')"
      fi
    fi
  fi

  if [[ "${NAT_ID}" == "None" || -z "${NAT_ID}" ]]; then
    NAT_INFO="$(aws ec2 describe-nat-gateways \
      --filter "Name=vpc-id,Values=${VPC_ID}" \
      --query 'NatGateways[?State!=`deleted`][0].[NatGatewayId,State]' --output text 2>/dev/null || echo "None")"
    if [[ "${NAT_INFO}" != "None" && -n "${NAT_INFO}" ]]; then
      NAT_ID="$(echo "${NAT_INFO}" | awk '{print $1}')"
      NAT_STATE="$(echo "${NAT_INFO}" | awk '{print $2}')"
    fi
  fi

  if [[ "${NAT_STATE}" == "failed" && "${NAT_ID}" != "None" && -n "${NAT_ID}" ]]; then
    echo "⚠️ NAT gateway ${NAT_ID} is in failed state; deleting to release EIP."
    aws ec2 delete-nat-gateway --nat-gateway-id "${NAT_ID}" >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      STATE="$(aws ec2 describe-nat-gateways --nat-gateway-ids "${NAT_ID}" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")"
      if [[ "${STATE}" == "deleted" || "${STATE}" == "None" ]]; then
        break
      fi
      sleep 10
    done
    NAT_ID="None"
    NAT_STATE="deleted"
    wait_for_eip_free "${EIP_ALLOC_ID}"
  fi

  if [[ "${NAT_STATE}" == "deleting" ]]; then
    echo "⏳ NAT gateway is deleting; waiting for EIP to be free before proceeding."
    wait_for_eip_free "${EIP_ALLOC_ID}"
    NAT_ID="None"
    NAT_STATE="deleted"
  fi

  if [[ "${NAT_ID}" != "None" && -n "${NAT_ID}" ]]; then
    if ! terraform state list 'aws_nat_gateway.main[0]' >/dev/null 2>&1; then
      echo "📥 Importing NAT Gateway: ${NAT_ID}"
      terraform import 'aws_nat_gateway.main[0]' "${NAT_ID}" || echo "⚠️ NAT import failed (ignoring)"
    fi
  else
    if [[ "${ENABLE_NAT}" == "true" && "${EIP_ALLOC_ID}" != "None" && -n "${EIP_ALLOC_ID}" ]]; then
      # If we couldn't find the NATGW through filters, but the EIP is already associated to a NATGW ENI,
      # adopt that NATGW instead of waiting for the EIP to become "free".
      adopt_nat_from_eip_association "${EIP_ALLOC_ID}" || true
      if [[ "${NAT_ID}" != "None" && -n "${NAT_ID}" ]]; then
        if ! terraform state list 'aws_nat_gateway.main[0]' >/dev/null 2>&1; then
          echo "📥 Importing NAT Gateway (from EIP association): ${NAT_ID}"
          terraform import 'aws_nat_gateway.main[0]' "${NAT_ID}" || echo "⚠️ NAT import failed (ignoring)"
        fi
      else
      wait_for_eip_free "${EIP_ALLOC_ID}"
      fi
    fi
  fi

  if [[ "${ENABLE_NAT}" == "true" ]]; then
    if ! terraform state list 'aws_eip.nat[0]' >/dev/null 2>&1; then
      if [[ "${EIP_ALLOC_ID}" == "None" || -z "${EIP_ALLOC_ID}" ]]; then
        if [[ "${NAT_ID}" != "None" && -n "${NAT_ID}" ]]; then
          EIP_ALLOC_ID="$(aws ec2 describe-nat-gateways --nat-gateway-ids "${NAT_ID}" \
            --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "None")"
        fi
      fi
      if [[ "${EIP_ALLOC_ID}" == "None" || -z "${EIP_ALLOC_ID}" ]]; then
        echo "⚠️ NAT EIP not found for ${NAME_PREFIX}; Terraform may allocate a new EIP."
      else
        echo "📥 Importing NAT EIP: aws_eip.nat[0] -> ${EIP_ALLOC_ID}"
        terraform import 'aws_eip.nat[0]' "${EIP_ALLOC_ID}" || echo "⚠️ EIP import failed (ignoring)"
      fi
    fi
  fi
fi

if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-deployer"

  AUTH_MODE="$(aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || true)"
  if [[ "${AUTH_MODE}" == "CONFIG_MAP" ]]; then
    echo "🔐 Updating cluster auth mode to API_AND_CONFIG_MAP (was CONFIG_MAP)..."
    UPDATE_JSON="$(aws eks update-cluster-config --name "${ENV_ID}" --region "${REGION}" --access-config authenticationMode=API_AND_CONFIG_MAP --output json || true)"
    UPDATE_ID="$(echo "${UPDATE_JSON:-}" | jq -r '.update.id // empty' 2>/dev/null || true)"
    if [[ -n "${UPDATE_ID:-}" ]]; then
      echo "⏳ Waiting for auth-mode update to complete: ${UPDATE_ID}"
      for i in $(seq 1 60); do
        STATUS="$(aws eks describe-update --name "${ENV_ID}" --region "${REGION}" --update-id "${UPDATE_ID}" --query 'update.status' --output text 2>/dev/null || true)"
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
    --cluster-name "${ENV_ID}" --region "${REGION}" \
    --principal-arn "${PRINCIPAL_ARN}" \
    >/dev/null 2>&1 || true

  aws eks associate-access-policy \
    --cluster-name "${ENV_ID}" --region "${REGION}" \
    --principal-arn "${PRINCIPAL_ARN}" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    >/dev/null 2>&1 || true

  ENTRY_ID="${ENV_ID}:${PRINCIPAL_ARN}"
  ASSOC_ID="${ENV_ID}#${PRINCIPAL_ARN}#arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  if terraform state list 'aws_eks_access_entry.current_caller[0]' >/dev/null 2>&1; then
    echo "✅ Access entry already in Terraform state: aws_eks_access_entry.current_caller[0]"
  else
    set +e
    OUT="$(terraform import -input=false -no-color 'aws_eks_access_entry.current_caller[0]' "${ENTRY_ID}" 2>&1)"
    RC=$?
    set -e
    if [[ "${RC}" -eq 0 ]]; then
      echo "${OUT}"
    elif echo "${OUT}" | grep -qi "Cannot import non-existent remote object"; then
      echo "EKS access entry not found; skipping import: ${ENTRY_ID}"
    elif echo "${OUT}" | grep -qi "Resource already managed by Terraform"; then
      echo "✅ Access entry already managed by Terraform; skipping import"
    else
      echo "${OUT}" >&2
      exit "${RC}"
    fi
  fi

  if terraform state list 'aws_eks_access_policy_association.current_caller_admin[0]' >/dev/null 2>&1; then
    echo "✅ Access policy association already in Terraform state: aws_eks_access_policy_association.current_caller_admin[0]"
  else
    set +e
    OUT="$(terraform import -input=false -no-color 'aws_eks_access_policy_association.current_caller_admin[0]' "${ASSOC_ID}" 2>&1)"
    RC=$?
    set -e
    if [[ "${RC}" -eq 0 ]]; then
      echo "${OUT}"
    elif echo "${OUT}" | grep -qi "Cannot import non-existent remote object"; then
      echo "EKS access policy association not found; skipping import: ${ASSOC_ID}"
    elif echo "${OUT}" | grep -qi "Resource already managed by Terraform"; then
      echo "✅ Access policy association already managed by Terraform; skipping import"
    else
      echo "${OUT}" >&2
      exit "${RC}"
    fi
  fi

  echo "🔗 Updating kubeconfig..."
  aws eks update-kubeconfig --name "${ENV_ID}" --region "${REGION}" || true

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

if aws eks describe-cluster --name "${ENV_ID}" --region "${REGION}" >/dev/null 2>&1; then
  if kubectl get ns "${ENV_ID}" >/dev/null 2>&1; then
    if ! terraform state list kubernetes_namespace.this >/dev/null 2>&1; then
      echo "📥 Importing existing Namespace: ${ENV_ID}"
      terraform import kubernetes_namespace.this "${ENV_ID}" || echo "⚠️ Namespace import failed (ignoring)"
    fi
  fi
fi

echo "✅ State Reconciliation Complete."
