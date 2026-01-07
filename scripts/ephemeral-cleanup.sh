#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Ephemeral Environment Cleanup Script
#
# Usage: ./ephemeral-cleanup.sh <MODE> <ENV_ID> <REGION> [ACCOUNT_ID]
# Modes: preflight|fallback|janitor|plan
# Examples:
#   ./ephemeral-cleanup.sh preflight pr-123 us-east-1
#   ./ephemeral-cleanup.sh fallback pr-123 us-east-1
#   ./ephemeral-cleanup.sh plan pr-123 us-east-1 (dry-run)
# ACCOUNT_ID defaults to 134051052096 if not provided
#
# This script is IDEMPOTENT. It can be run:
# 1. As "Preflight" to clean up orphans before a fresh deploy.
# 2. As "Fallback" if Terraform Destroy fails.
# 3. As "Janitor" to clean up closed PRs.
# ==============================================================================

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <MODE> <ENV_ID> <REGION> [ACCOUNT_ID]"
    echo "Modes: preflight|fallback|janitor|plan"
    exit 1
fi

MODE="$1"
ENV_ID="$2"
REGION="$3"
CLUSTER="${ENV_ID}"
PREFIX="${ENV_ID}-ephemeral"
# Default ACCOUNT_ID, can be overridden
ACCOUNT_ID="${4:-134051052096}"

# Validate mode
case "$MODE" in
    preflight|fallback|janitor|plan) ;;
    *) echo "Error: MODE must be preflight, fallback, janitor, or plan"; exit 1 ;;
esac

# Plan mode is dry-run
if [ "$MODE" = "plan" ]; then
    echo "🧪 PLAN MODE: This is a dry-run. No resources will be deleted."
    DRY_RUN="true"
else
    DRY_RUN="false"
fi

# ✅ AWS CLI environment (prevent pager hangs, ensure region is respected)
export AWS_PAGER=""
export AWS_DEFAULT_REGION="$REGION"
export AWS_REGION="$REGION"

echo "🧹 Starting $MODE cleanup for ENV_ID: $ENV_ID (Prefix: $PREFIX) in $REGION..."

# ==============================================================================
# 1. Load Balancers (Orphaned by Controller)
# ==============================================================================
echo "::group::Cleanup: Load Balancers"
# Skip load balancer cleanup for now to avoid hanging - they will be cleaned up by the main terraform destroy if needed
echo "ℹ️ Skipping load balancer cleanup to avoid potential hangs"
echo "::endgroup::"

# ==============================================================================
# 2. EKS Resources (Cluster, Nodes, Fargate)
# ==============================================================================
echo "::group::Cleanup: EKS Resources"

# Preflight: skip EKS teardown (cluster APIs require live cluster and are noisy if absent)
if [ "$MODE" != "preflight" ]; then
    # Fallback/Janitor mode: scorched earth
    for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text 2>/dev/null || true); do
        [ -z "$ng" ] && continue
        if [ "$DRY_RUN" = "true" ]; then
            echo "📋 Would delete nodegroup: $ng"
        else
            echo "Deleting nodegroup: $ng"
            aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" || true
            timeout 20m aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$ng" || true
        fi
    done

    for fp in $(aws eks list-fargate-profiles --cluster-name "$CLUSTER" --query 'fargateProfileNames[]' --output text 2>/dev/null || true); do
        [ -z "$fp" ] && continue
        if [ "$DRY_RUN" = "true" ]; then
            echo "📋 Would delete fargate profile: $fp"
        else
            echo "Deleting fargate profile: $fp"
            aws eks delete-fargate-profile --cluster-name "$CLUSTER" --fargate-profile-name "$fp" || true
            timeout 20m aws eks wait fargate-profile-deleted --cluster-name "$CLUSTER" --fargate-profile-name "$fp" || true
        fi
    done

    # Cluster deletion only in fallback/janitor modes
    if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = "true" ]; then
            echo "📋 Would delete cluster: $CLUSTER"
        else
            echo "Deleting cluster: $CLUSTER"
            aws eks delete-cluster --name "$CLUSTER" || true
            timeout 20m aws eks wait cluster-deleted --name "$CLUSTER" || true
        fi
    else
        echo "Cluster $CLUSTER not found (already deleted)."
    fi
fi
echo "::endgroup::"

# ==============================================================================
# 3. RDS Instances
# ==============================================================================
echo "::group::Cleanup: RDS"
dbs=$(aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, '${PREFIX}')].DBInstanceIdentifier" --output text 2>/dev/null || true)
for db in $dbs; do
    [ -z "$db" ] && continue
    if [ "$DRY_RUN" = "true" ]; then
        echo "📋 Would delete DB: $db"
    else
        echo "Deleting DB: $db"
        aws rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups || true
        aws rds wait db-instance-deleted --db-instance-identifier "$db" || true
    fi
done

# Clean groups (best effort, depend on DB deletion)
if [ "$DRY_RUN" = "true" ]; then
    echo "📋 Would delete DB parameter group: ${PREFIX}-postgres-params"
    echo "📋 Would delete DB subnet group: ${PREFIX}-db-subnet-group"
else
    aws rds delete-db-parameter-group --db-parameter-group-name "${PREFIX}-postgres-params" >/dev/null 2>&1 || true
    aws rds delete-db-subnet-group --db-subnet-group-name "${PREFIX}-db-subnet-group" >/dev/null 2>&1 || true
fi
echo "::endgroup::"

# ==============================================================================
# 4. VPC Resources (NAT, EIP)
# ==============================================================================
echo "::group::Cleanup: VPC Resources"
# NAT Gateways (EC2 describe + tag filter)
nats=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null || true)

if [ -z "${nats:-}" ]; then
    echo "ℹ️ No tagged NATs found."
else
    for nat_id in $nats; do
        [ -z "$nat_id" ] && continue

        if [ "$DRY_RUN" = "true" ]; then
            echo "📋 Would delete NAT: $nat_id"
        else
            echo "Deleting NAT: $nat_id"
            alloc_ids=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" \
                --query 'NatGateways[].NatGatewayAddresses[].AllocationId' --output text 2>/dev/null || true)

            aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" || true
            timeout 20m aws ec2 wait nat-gateway-deleted --nat-gateway-id "$nat_id" || true

            for alloc in $alloc_ids; do
                [ -z "$alloc" ] && continue
                echo "Releasing EIP: $alloc (from deleted NAT $nat_id)"
                aws ec2 release-address --allocation-id "$alloc" || true
            done
        fi
    done
fi

# Clean up tagged EIPs
eips=$(aws ec2 describe-addresses \
    --filter "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
    --query 'Addresses[].AllocationId' \
    --output text 2>/dev/null || true)

for eip_id in $eips; do
    [ -z "$eip_id" ] && continue
    if [ "$DRY_RUN" = "true" ]; then
        echo "📋 Would release EIP: $eip_id"
    else
        echo "Releasing EIP: $eip_id"
        aws ec2 release-address --allocation-id "$eip_id" || true
    fi
done
echo "::endgroup::"

# ==============================================================================
# 5. Target Groups (Common ALB artifacts that may linger)
# ==============================================================================
echo "::group::Cleanup: Target Groups"
# Skip target group cleanup for now to avoid hanging - they will be cleaned up by the main terraform destroy if needed
echo "ℹ️ Skipping target group cleanup to avoid potential hangs"
echo "::endgroup::"

# ==============================================================================
# 6. Network Interfaces (Must clean before Security Groups)
# ==============================================================================
echo "::group::Cleanup: Network Interfaces"
ENIS="$(aws ec2 describe-network-interfaces \
    --filters "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text 2>/dev/null || true)"

if [ -n "$ENIS" ]; then
    for eni_id in $ENIS; do
        [ -z "$eni_id" ] && continue
        if [ "$DRY_RUN" = "true" ]; then
            echo "📋 Would delete ENI: $eni_id"
        else
            echo "Deleting ENI: $eni_id"
            aws ec2 delete-network-interface --network-interface-id "$eni_id" || true
        fi
    done
else
    echo "No network interfaces found for this environment."
fi
echo "::endgroup::"

# ==============================================================================
# 7. Security Groups (Tagged by environment)
# ==============================================================================
echo "::group::Cleanup: Security Groups"
SGS="$(aws ec2 describe-security-groups \
    --filters "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || true)"

if [ -n "$SGS" ]; then
    for sg_id in $SGS; do
        [ -z "$sg_id" ] && continue
        group_name="$(aws ec2 describe-security-groups --group-ids "$sg_id" --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || true)"
        [ "$group_name" = "default" ] && continue

        attempt=1
        max_attempts=3
        deleted="false"
        while [ $attempt -le $max_attempts ]; do
            if [ "$DRY_RUN" = "true" ]; then
                echo "📋 Would delete security group: $sg_id ($group_name)"
                deleted="true"
                break
            fi
            echo "Deleting security group: $sg_id ($group_name) (attempt $attempt/$max_attempts)"
            if aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1; then
                deleted="true"
                break
            fi
            sleep 10
            attempt=$((attempt + 1))
        done

        # Emit warning if delete failed after retries
        if [ "$deleted" = "false" ]; then
            echo "::warning::Failed to delete security group $sg_id ($group_name) after $max_attempts attempts"
            # Show dependencies for debugging
            aws ec2 describe-security-groups --group-ids "$sg_id" \
                --query 'SecurityGroups[0].{Ingress:IpPermissions,Egress:IpPermissionsEgress}' \
                --output json 2>/dev/null || true
        fi
    done
else
    echo "No security groups found for this environment."
fi
echo "::endgroup::"

# ==============================================================================
# 7. IAM Cleanup Helpers
# ==============================================================================
delete_iam_policy_by_name() {
    local name="$1"
    local arn
    arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${name}'].Arn | [0]" --output text 2>/dev/null || true)"
    if [ -z "$arn" ] || [ "$arn" = "None" ]; then return 0; fi
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "📋 Would delete Policy: $name"
        return 0
    fi

    echo "Deleting Policy: $name"
    # Detach entities
    for r in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyRoles[].RoleName' --output text || true); do
        aws iam detach-role-policy --role-name "$r" --policy-arn "$arn" || true
    done
    for u in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyUsers[].UserName' --output text || true); do
        aws iam detach-user-policy --user-name "$u" --policy-arn "$arn" || true
    done
    for g in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyGroups[].GroupName' --output text || true); do
        aws iam detach-group-policy --group-name "$g" --policy-arn "$arn" || true
    done
    
    # Delete versions
    for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text || true); do
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" || true
    done
    aws iam delete-policy --policy-arn "$arn" || true
}

delete_iam_role_by_name() {
    local role="$1"
    aws iam get-role --role-name "$role" >/dev/null 2>&1 || return 0
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "📋 Would delete Role: $role"
        return 0
    fi

    echo "Deleting Role: $role"
    # Detach instance profiles
    for ip in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text || true); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" || true
        aws iam delete-instance-profile --instance-profile-name "$ip" || true
    done

    # Detach managed policies
    for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text || true); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$p" || true
    done
    
    # Delete inline policies
    for ip in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text || true); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$ip" || true
    done
    
    aws iam delete-role --role-name "$role" || true
}

# ==============================================================================
# 8. General Cleanup (Secrets, Logs, ECR, IAM, Cache)
# ==============================================================================
echo "::group::Cleanup: General Resources"

if [ "$DRY_RUN" = "true" ]; then
    echo "📋 Would delete log group: /aws/eks/${CLUSTER}/cluster"
    echo "📋 Would delete budgets: ${PREFIX}-monthly-budget, ${PREFIX}-eks-budget"
    echo "📋 Would delete secrets: ${PREFIX}/application/backend/redis, etc."
    echo "📋 Would delete ECR repos: ${PREFIX}-backend, ${PREFIX}-frontend"
    echo "📋 Would delete IAM roles and policies (prefixed with ${PREFIX})"
    echo "📋 Would delete ElastiCache serverless caches (prefixed with ${PREFIX})"
    echo "📋 Would delete Kubernetes namespace: ${ENV_ID}"
    echo "📋 Would uninstall Helm releases in namespace: ${ENV_ID}"
else
    # Kubernetes cleanup (if cluster still exists)
    if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
        echo "🧹 Cleaning up Kubernetes resources..."

        # Update kubeconfig
        aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" || true

        # Delete namespace (this will cascade delete all resources in it)
        kubectl delete namespace "$ENV_ID" --ignore-not-found=true --timeout=60s || true

        # Try to uninstall specific helm releases if they exist
        helm uninstall aws-load-balancer-controller --namespace kube-system --ignore-not-found || true
        helm uninstall external-dns --namespace kube-system --ignore-not-found || true
        helm uninstall external-secrets --namespace kube-system --ignore-not-found || true
    fi

    # Logs & Budgets
    echo "🧹 Force deleting CloudWatch log group..."
    aws logs delete-log-group --log-group-name "/aws/eks/${CLUSTER}/cluster" --force || true
    aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "${PREFIX}-monthly-budget" >/dev/null 2>&1 || true
    aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "${PREFIX}-eks-budget" >/dev/null 2>&1 || true

    # Secrets
    aws secretsmanager delete-secret --secret-id "${PREFIX}/application/backend/redis" --force-delete-without-recovery >/dev/null 2>&1 || true
    aws secretsmanager delete-secret --secret-id "${PREFIX}/application/encryption_key" --force-delete-without-recovery >/dev/null 2>&1 || true
    aws secretsmanager delete-secret --secret-id "${PREFIX}/application/aws/client" --force-delete-without-recovery >/dev/null 2>&1 || true
    aws secretsmanager delete-secret --secret-id "${PREFIX}/database/postgres" --force-delete-without-recovery >/dev/null 2>&1 || true

    # ECR
    aws ecr delete-repository --repository-name "${PREFIX}-backend" --force >/dev/null 2>&1 || true
    aws ecr delete-repository --repository-name "${PREFIX}-frontend" --force >/dev/null 2>&1 || true

    # Roles
    delete_iam_role_by_name "${PREFIX}-rds-monitoring-role"
    delete_iam_role_by_name "${PREFIX}-eks-cluster-role"
    delete_iam_role_by_name "${PREFIX}-eks-node-role"
    delete_iam_role_by_name "${PREFIX}-aws-load-balancer-controller-role"
    delete_iam_role_by_name "${PREFIX}-external-dns-role"
    delete_iam_role_by_name "${PREFIX}-ebs-csi-driver-role"
    delete_iam_role_by_name "${PREFIX}-app-role"
    delete_iam_role_by_name "${PREFIX}-external-secrets-role"
    delete_iam_role_by_name "${PREFIX}-client-discovery-role"

    # Policies
    delete_iam_policy_by_name "${PREFIX}-aws-load-balancer-controller-policy"
    delete_iam_policy_by_name "${PREFIX}-external-dns-assume-dns-authority-policy"
    delete_iam_policy_by_name "${PREFIX}-node-additional-policy"
    delete_iam_policy_by_name "${PREFIX}-app-policy"
    delete_iam_policy_by_name "${PREFIX}-external-secrets-policy"

    # ElastiCache
    for c in $(aws elasticache describe-serverless-caches --query "ServerlessCaches[?starts_with(ServerlessCacheName, '${PREFIX}')].ServerlessCacheName" --output text || true); do
        aws elasticache delete-serverless-cache --serverless-cache-name "$c" >/dev/null 2>&1 || true
    done
fi
echo "::endgroup::"

echo "✅ Cleanup script complete."
