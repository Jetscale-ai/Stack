# Terraform Import vs Data Sources: Reconsidered

## The Challenge
When `reuse_existing_vpc=true`, the VPC exists in AWS but Terraform state might be lost. What happens to dependent resources?

## Problem with Pure Data Source Approach

```hcl
# VPC created in run 1, state exists
resource "aws_vpc" "main" { ... }           # vpc-123 in state
resource "aws_subnet" "public" {           # subnet-456 in state
  vpc_id = aws_vpc.main.id
}

# Run 2: reuse_existing_vpc=true, state lost
data "aws_vpc" "existing" { ... }           # finds vpc-123
resource "aws_vpc" "main" { count = 0 }    # not created
resource "aws_subnet" "public" {           # TRIES to create subnet-789
  vpc_id = data.aws_vpc.existing.id         # vpc-123 (same VPC)
}                                          # FAILS: subnet already exists
```

**Result**: Dependent resources try to create duplicates!

## Import Approach

```bash
# Before terraform apply:
if [ "$REUSE_VPC" = "true" ]; then
  terraform state list aws_vpc.main >/dev/null 2>&1 || {
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:jetscale.env_id,Values=$ENV_ID" --query 'Vpcs[0].VpcId' --output text)
    terraform import aws_vpc.main $VPC_ID
  }
fi

# Then terraform apply works normally
```

**Result**: Terraform knows VPC exists, dependent resources are properly tracked.

## Hybrid Approach (Recommended)

```hcl
# Always have the resource, but make it conditional on existence
resource "aws_vpc" "main" {
  # Normal config, but lifecycle prevents destroy
  lifecycle {
    prevent_destroy = var.reuse_existing_vpc
  }
}

# OR: Use data source + conditional resources
data "aws_vpc" "existing" {
  count = var.reuse_existing_vpc ? 1 : 0
  # filters
}

# Import logic in CI/CD handles the state sync
```

## Conclusion: Import IS Needed

For proper state management, we should:

1. Use `terraform import` to sync existing AWS resources into Terraform state
2. Keep the `resource "aws_vpc" "main"` always present (not conditional)
3. Use lifecycle rules to prevent destroying imported resources
4. Import all dependent resources (subnets, IGW, etc.) as needed

This ensures Terraform has complete knowledge of all infrastructure.
