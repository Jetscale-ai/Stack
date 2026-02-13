# Environment Configuration

This directory contains Helm values files for different environments and cloud providers. The structure supports multi-cloud deployments with environment-specific overrides.

## Directory Structure

```text
envs/
├── aws.yaml                    # AWS-specific configuration (cloud provider)
├── staging/
│   ├── default.yaml           # Staging environment defaults
│   └── jetscale.yaml          # Jetscale environment values
├── prod/
│   ├── default.yaml           # Production environment defaults
│   ├── console.yaml           # Jetscale Console project values
│   └── demo.yaml              # Jetscale Demo project values
└── preview/
    └── preview.yaml           # Preview environment values
```

## Values File Precedence

Helm merges multiple values files in order, with **later files taking precedence** over earlier ones. The validation process applies values in this order:

1. **Base Chart Values** (implicit)
   - `charts/jetscale/values.yaml` - Default values for the JetScale chart

2. **Cloud Provider Values** (required)
   - `envs/<cloud>.yaml` (e.g., `envs/aws.yaml`)
   - Contains cloud-specific configuration:
     - AWS ALB Ingress annotations

3. **Environment Type Defaults** (optional)
   - `envs/<env-type>/default.yaml` (e.g., `envs/prod/default.yaml`)
   - Contains environment-wide settings:
     - Replica counts (production vs staging)
     - Resource limits and requests
     - Pod Disruption Budgets (PDB)

4. **Environment/Client-Specific Values** (required)
   - `envs/<env-type>/<project-name>.yaml` (e.g., `envs/prod/console.yaml`)
   - Contains project or deployment-specific values:
     - Domain names and hostnames
     - Feature flags
     - Environment-specific secrets references

## Validation

To validate all environment configurations with Helm templates:

```bash
# Validate using AWS cloud provider values
mage validate:envs aws
```

The validation command:

- Runs `helm template` against all discovered environment configurations
- Ensures all values files produce valid Kubernetes YAML
- Does **not** require a running cluster
- Shows which values files are applied in order

## Best Practices

- **Cloud provider files** (`envs/aws.yaml`, etc.) should contain only cloud-specific infrastructure settings
- **Environment defaults** (`default.yaml`) should contain settings shared across all deployments in that environment type
- **Project values** (`<project-name>.yaml`) should contain deployment-specific configuration
- Use **top-level envs files** (like `envs/default.yaml`) only for documentation or temporary values - they are excluded from validation
- Keep secrets in external secret managers; reference them via environment variables or Kubernetes secrets
- Test all changes with `mage validate:envs` before committing

## Troubleshooting

### Error: "cloud values file not found"

- Ensure you've created the required cloud provider file (e.g., `envs/aws.yaml`)
- The cloudName argument must match an existing file in the envs directory

### Error: "no YAML files found in envs directory"

- Create at least one environment subdirectory with a `values.yaml` file
- Ensure files have `.yaml` or `.yml` extensions

### Validation fails with template errors

- Check the "Values files (in order)" output to see which files are being applied
- Verify that later files properly override earlier values
- Use `helm template` directly with `--debug` for detailed error information
