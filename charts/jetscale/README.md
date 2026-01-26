# Jetscale Helm Umbrella Chart

This Helm chart is the umbrella (parent) chart for installing Jetscale.

> **Developer Workflows:** See the root [README.md](../../README.md#4-developer-lifecycle) for how to use these value files in the Dev/Verify/CI/Debug loops.

## Ownership (Fractal Franchise)

This chart is **built** here and **deployed by ArgoCD**. It is not deployed by running `helm install` manually in live clusters.

| Repo | Role |
| :--- | :--- |
| `../../../iac/` | Infrastructure + Argo bootstrap |
| `../../../catalog/` | Blueprint patterns (How to install) |
| `../../../fleet/` | Deployment state (What is installed) |

## Chart Structure

```text
charts/jetscale/
├── Chart.yaml          # Dependencies + version
├── Chart.lock          # Lockfile (committed)
├── templates/          # K8s resource templates
├── values.yaml         # Base defaults (always loaded)
└── values.*.yaml       # Lifecycle-specific overrides
```

## Value Files Reference

| File | Lifecycle Phase | Purpose |
| :--- | :--- | :--- |
| `values.yaml` | All | Base defaults (Helm always loads this) |
| `values.local.dev.yaml` | Dev Loop | Hot reload, Tilt integration |
| `values.test.yaml` | Verify + CI | Shared test base (ephemeral DB/Redis) |
| `values.test.local.yaml` | Verify | Local E2E with locally-built images |
| `values.test.ci.yaml` | CI Loop | CI E2E with GHCR images |
| `values.local.live.yaml` | Debug | Pulls production images for local debugging |

Environment deployments (Preview/Live) use files under `../../envs/` composed as:

```text
envs/aws.yaml → envs/<type>/default.yaml → envs/<type>/<client>.yaml
```

## Local Chart Development

### Link Mode (for editing child charts)

When modifying a child chart simultaneously, use a file reference in `Chart.yaml`:

```yaml
dependencies:
  - name: backend
    alias: backend-api
    # repository: "oci://ghcr.io/jetscale-ai/charts"  # Production
    repository: "file://../../../Backend/chart"       # Link Mode
```

> **Warning:** File references must never be committed to `main`.

### Render & Validate

```bash
# Render templates (dry-run)
helm template test . --output-dir renders/

# Validate against cluster (without applying)
helm upgrade --install test . -n test-ns --dry-run=server

# View diff before upgrade (requires helm-diff plugin)
helm diff upgrade test . -f values.local.dev.yaml
```
