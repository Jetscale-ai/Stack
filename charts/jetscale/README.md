# Jetscale Helm Umbrella Chart

This Helm chart is the umbrella (parent) chart for installing Jetscale.

## 🏗 Deployment & Ownership (Fractal Franchise)

This chart is **built** here and **deployed by ArgoCD**. It is not deployed by running `helm install` manually in live clusters.

- **Infrastructure + Argo bootstrap:** `../../../iac/README.md`
- **Blueprint patterns (How to install):** `../../../catalog/README.md`
- **Deployment state (What is installed):** `../../../fleet/README.md`

Direct Helm commands in this README are intended for **local Kind / debugging** only.

### Structure description
- templates/ : Helm template files (ex. ingress.yaml)
  - Those resources are touch/are used by all the childs chart
- values.yaml : Default values for the Chart - see Value files section below
- renders/ : [optional] - Created to see rendered K8s yaml file (see below)
- Chart.yaml : Definition, version and dependancies of the chart

## Value files

Outside of the default values defined in values.yaml, there are a few other value files here for different scenarios:

| Value file | Description | Comments |
|----------|----------|----------|
| values.yaml | Default values for the umbrella chart | Helm always loads this file |
| values.ci.kind.yaml | CI configuration for Kind cluster testing | Used in GitHub Actions CI pipeline |
| values.local.dev.yaml | Local development with hot reload | Used by Tilt (`Tiltfile`) |
| values.local.e2e.yaml | Local E2E tests using locally built images | Used by `tests/e2e` + Kind |
| values.local.live.yaml | Live-parity local mode | Pulls published images (no local builds) |
| values.local.yaml | Local base configuration | Shared defaults for local workflows |

Environment deployments (staging/live/preview) are defined under `envs/` and composed as:
`envs/<cloud>.yaml` → `envs/<type>/default.yaml` → `envs/<type>/<client>.yaml`

**Production note:** The authoritative live configuration (domains, replicas, versions) lives in `../../../fleet/` and is applied by ArgoCD.

## Dev/Test

If you are modifying the child chart at the same time, note that you can use the file ref in Chart.yaml. Exemple:
```
dependencies:
  # Backend Service (Proprietary OCI)
  - name: backend
    alias: backend-api
    # Point to the parent namespace, Helm appends the name
    # repository: "oci://ghcr.io/jetscale-ai/charts"
    repository: "file://../../../Backend/chart"
```

To render the chart, giving it a release name: `helm template test .`

Useful arguments:
- Add another values file (on top of the default ./values.yaml): `-f values.api.yaml`
  - Note that you can chain multiple files, the last ones taking precedence
- Render in different file in a directory: `--output-dir renders/`

To test on a K8s cluster without applying: `helm upgrade --install test . --create-namespace -n <TEST-NS> --dry-run=server`


### Local Installation/Upgrade (debug only)

Installation with the creation of a namespace: `helm upgrade --install test . --create-namespace -n <TEST-NS> -f examples/values.ws.yaml`

Before doing an upgrade, the diff Helm plugin is useful to see the applied difference that would be applied: https://github.com/bus23/helm-diff?tab=readme-ov-file

Checking the diff of an upgrade: `helm diff upgrade test . -f values.jetscale.yaml`

Upgrading: you can use the same command as the installation (above)
