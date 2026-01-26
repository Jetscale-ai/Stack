# Terraform State Analysis: Import vs Data Sources for VPC Reuse

## Current Approach (Data Sources)

```hcl
variable "reuse_existing_vpc" { type = bool }

data "aws_vpc" "existing" {
  count = var.reuse_existing_vpc ? 1 : 0
  # Filters by tags
}

resource "aws_vpc" "main" {
  count = var.reuse_existing_vpc ? 0 : 1
  # Creates VPC
}

locals {
  vpc_id = var.reuse_existing_vpc ? data.aws_vpc.existing[0].id : aws_vpc.main[0].id
}

# All dependent resources use local.vpc_id
resource "aws_subnet" "public" {
  vpc_id = local.vpc_id
}
```

## Alternative Approach (Import)

```bash
# Manual import command
terraform import aws_vpc.main vpc-12345678

# Then change config to reference existing
resource "aws_vpc" "main" {
  # lifecycle { prevent_destroy = true } or similar
}
```

## Why Data Sources Are Better

### 1. Declarative vs Imperative

- **Data Sources**: Terraform automatically resolves VPC by tags

- **Import**: Requires manual intervention and scripting

### 2. State Management

- **Data Sources**: No VPC resource in state when reusing
- **Import**: VPC always in state, even when "imported"

### 3. Error Recovery

- **Data Sources**: If state lost, next run finds VPC by tags
- **Import**: If state lost, need to re-import manually

### 4. Workflow Complexity

- **Data Sources**: Simple flag flip in variables
- **Import**: Need to detect missing state + run import command

## The Import Problem

```bash
# This would be needed in workflow:
if [ "$REUSE_VPC" = "true" ]; then
  # Check if VPC in state
  terraform state list aws_vpc.main >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    # Get VPC ID from AWS
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:jetscale.env_id,Values=$ENV_ID" --query 'Vpcs[0].VpcId' --output text)
    # Import it
    terraform import aws_vpc.main $VPC_ID
  fi
fi
```

This adds significant complexity and potential for race conditions.

## Recommendation: Stick with Data Sources

The current data source approach is:

- ✅ Automatic and declarative
- ✅ Handles state loss gracefully
- ✅ Simple workflow logic
- ✅ No manual import steps needed
