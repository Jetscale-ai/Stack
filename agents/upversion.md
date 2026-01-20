# Chart Bump Protocol

## Overview
Periodically upgrade backend/frontend charts and images to latest versions.

**Versioning Strategy (Sovereign Source):**
- **Human Role:** You update the **dependencies** (logic/composition) in the PR.
- **CI Role:** The pipeline calculates the Semantic Version, updates `Chart.yaml`, publishes the OCI artifact, and **commits the new version back to main**.
- **Result:** Code always reflects truth.

## Prerequisites
- `gh` CLI installed
- `helm` installed
- `mage` installed

## Protocol Steps

### 1. Query Latest Versions
Find the latest tags for the sub-services.
```bash
# Backend
gh api repos/Jetscale-ai/backend/packages/container/charts%2Fbackend/versions --jq '.[].metadata.container.tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1

# Frontend
gh api repos/Jetscale-ai/frontend/packages/container/charts%2Ffrontend/versions --jq '.[].metadata.container.tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
```

### 2. Update Chart Dependencies
Edit `charts/jetscale/Chart.yaml` with the versions found above.

```yaml
dependencies:
  - name: backend
    version: "3.1.5" # <--- Update
  - name: frontend
    version: "2.1.3" # <--- Update
```

### 3. Regenerate Lockfile (CRITICAL)
This validates that the new dependencies exist in the registry and binds the chart to them.

```bash
cd charts/jetscale
helm dependency update
```

### 4. Validate Integrity
Ensure the chart is valid and compatible with our environment configurations.

```bash
cd ../..
mage validate:envs aws
```

### 5. Commit
The commit message triggers the release.
**Do not bump `version` manually.** CI will handle it.

```bash
# Use "fix" (patch) or "feat" (minor) to trigger the appropriate bump.
pnpm commit -- "fix(deps): bump backend to 3.1.5 and frontend to 2.1.3"
```

## Files to Update
- `charts/jetscale/Chart.yaml` (dependencies only)
- `charts/jetscale/Chart.lock` (regenerate)

## Validation Checklist
- [ ] Latest versions queried successfully
- [ ] Chart dependencies updated
- [ ] Chart.lock regenerated
- [ ] `mage validate:envs aws` passes
- [ ] Conventional commit message used
- [ ] CI will handle version bump and commit-back