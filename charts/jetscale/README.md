# Jetscale Helm Umbrella Chart

This Helm chart is the umbrella (parent) chart for installing Jetscale.

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
| values.ci.kind.yaml    |      |      |
| values.jetscale.yaml    |  Default values for AWS Jetscale deployment    | To be used by a env. specific values (envs/)   |
| values.local.dev.yaml    |      |      |
| values.local.e2e.yaml     | E2E tests using newly built image (from local ref)     |      |
| values.local.yaml |  |  |

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

To test on a K8s cluster without applying: `helm upgrade --install test . --create-namespace -n <TEST-NS> -f values.jetscale.yaml --dry-run=server`


### Installation/Upgrade

Installation with the creation of a namespace: `helm upgrade --install test . --create-namespace -n <TEST-NS> -f examples/values.ws.yaml`

Before doing an upgrade, the diff Helm plugin is useful to see the applied difference that would be applied: https://github.com/bus23/helm-diff?tab=readme-ov-file

Checking the diff of an upgrade: `helm diff upgrade test . -f values.jetscale.yaml`

Upgrading: you can use the same command as the installation (above)
