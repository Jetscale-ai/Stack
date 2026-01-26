# Terraform Import Solution for VPC Reuse

## The Problem

When reusing an existing VPC, dependent resources (subnets, IGW, etc.) may already exist but not be in Terraform state. Terraform will try to create duplicates.

## Solution: Conditional Import + Resource Adoption

### 1. Keep VPC Resource Always Present

```hcl
resource "aws_vpc" "main" {
  # Always present in config
  cidr_block = var.vpc_cidr
  # ... other config ...

  lifecycle {
    prevent_destroy = var.reuse_existing_vpc
  }
}
```

### 2. Add Import Logic to Workflow

```yaml
- name: Sync Terraform State for VPC Reuse
  if: env.REUSE_VPC == 'true'
  working-directory: iac/clients
  run: |
    # Import VPC if not in state
    terraform state list aws_vpc.main >/dev/null 2>&1 || {
      VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:jetscale.env_id,Values=${{ env.ENV_ID }}" --query 'Vpcs[0].VpcId' --output text)
      echo "Importing VPC: $VPC_ID"
      terraform import aws_vpc.main $VPC_ID
    }

    # Import dependent resources as needed
    # (subnets, IGW, etc.)

```

### 3. Handle Dependent Resources

For resources like subnets that might already exist:

```hcl
data "aws_subnets" "existing" {
  count = var.reuse_existing_vpc ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }

  filter {
    name   = "tag:jetscale.env_id"
    values = [var.tenant_id]
  }
}

resource "aws_subnet" "public" {
  count = var.reuse_existing_vpc ? 0 : 1  # Don't create if reusing

  # ... config ...
}

# OR: Use for_each with data source
resource "aws_subnet" "public" {
  for_each = var.reuse_existing_vpc ? {} : {for idx, az in local.availability_zones : idx => az}
  # ... config ...
}
```

## Why Import Is Better

1. **Complete State Tracking**: Terraform knows about ALL resources
2. **Proper Dependencies**: Resources can reference each other normally
3. **Plan/Apply Work**: `terraform plan` shows actual changes
4. **Destroy Works**: Can properly destroy when PR closes

## Implementation Steps

1. **IaC**: Keep `resource "aws_vpc" "main"` always present
2. **Workflow**: Add import step when `REUSE_VPC=true`
3. **Testing**: Verify import doesn't break fresh VPC creation

This ensures robust state management for both create and reuse scenarios.
