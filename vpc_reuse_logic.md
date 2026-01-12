# VPC Reuse Logic for Ephemeral PR Environments

## Decision Flow

### Step 1: Check if VPC Already Exists in AWS
```bash
VPC_EXISTS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:jetscale.env_id,Values=${ENV_ID}" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "None")
```

### Step 2: Set reuse_existing_vpc Flag
```bash
if [ "$VPC_EXISTS" != "None" ]; then
  REUSE_VPC=true
  echo "✅ Found existing VPC $VPC_EXISTS for PR $ENV_ID, will reuse"
else  
  REUSE_VPC=false
  echo "🆕 No existing VPC found for PR $ENV_ID, will create new one"
fi
```

### Step 3: Generate Terraform Variables
```json
{
  "reuse_existing_vpc": $REUSE_VPC,
  "tenant_id": "$ENV_ID"
}
```

## Why This Works

### First Run (New PR)
- AWS query returns "None" 
- `reuse_existing_vpc=false`
- Terraform creates new VPC with tags
- VPC tagged: `jetscale.env_id=pr-4`

### Subsequent Runs (Same PR)
- AWS query finds VPC with `jetscale.env_id=pr-4`
- `reuse_existing_vpc=true` 
- Terraform reuses existing VPC
- No new VPC created, stays within quota

### Failed Run Recovery
- If VPC was partially created but terraform state lost
- AWS still has the VPC with correct tags
- Next run finds it and reuses it
- Terraform state gets reconstructed

## Safety Checks

### Terraform State Consistency
- If VPC exists but terraform state is missing/corrupt
- Terraform will import existing VPC on next run
- No duplicate VPC creation

### Tag-Based Ownership
- Only reuses VPCs owned by this specific PR
- `jetscale.env_id=pr-4` ensures isolation
- `jetscale.lifecycle=ephemeral` ensures cleanup
