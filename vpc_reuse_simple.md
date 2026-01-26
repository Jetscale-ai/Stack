# Simple VPC Reuse: No IaC Changes Needed

## Current Situation

- IaC cannot be modified (human only)
- VPC limit hit during terraform apply
- Need to reuse VPCs for same PR

## Simple Solution: State Manipulation Only

### 1. No IaC Changes

Keep existing terraform config unchanged. No lifecycle rules, no conditionals.

### 2. Workflow Logic: Import on Reuse

```yaml
- name: Handle VPC Reuse
  if: env.REUSE_VPC == 'true'
  working-directory: iac/clients
  run: |
    # Import existing VPC into terraform state
    VPC_ID=$(aws ec2 describe-vpcs \
      --filters "Name=tag:jetscale.env_id,Values=${{ env.ENV_ID }}" \
      --query 'Vpcs[0].VpcId' --output text)

    if [ "$VPC_ID" != "None" ]; then
      echo "Importing VPC: $VPC_ID"
      terraform import aws_vpc.main $VPC_ID

      # Import other resources as needed
      # terraform import aws_internet_gateway.main $IGW_ID
      # etc.
    fi

```

### 3. Terraform Apply

Works normally - terraform knows VPC exists via imported state.

### 4. Terraform Destroy

Works normally - destroys imported VPC just like created VPC.

## Why This Works

### First Run

- No VPC exists → terraform create → VPC in state

### Subsequent Runs

- VPC exists in AWS → terraform import → VPC in state

- terraform apply sees "no changes" for VPC
- Creates/updates dependent resources normally

### PR Close

- terraform destroy destroys everything, including imported VPC

## Minimal IaC Impact

- No code changes needed
- Only workflow logic to detect + import existing VPCs
- Destroy works the same way regardless of create vs import

This respects the "human only" IaC modification rule while solving the VPC quota issue.
