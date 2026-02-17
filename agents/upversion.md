# Chart Bump Protocol

## Overview

Upgrade backend/frontend charts to the latest versions.

**Versioning Strategy (Sovereign Source):**

- **Human Role:** Update the **dependencies** (logic/composition) in the PR.
- **CI Role:** The pipeline calculates the SemVer, updates `Chart.yaml`, publishes the OCI artifact, and **commits the new version back to main**.
- **Result:** `main` reflects the released artifact.

## Quick Start (Automated)

Use the helper script for one-command updates:

```bash
# Check for updates (dry-run)
./scripts/check-chart-updates.sh

# Apply updates (edits Chart.yaml, runs helm deps update)
./scripts/check-chart-updates.sh --apply

# Apply and validate
./scripts/check-chart-updates.sh --validate
```

See `.agents/skills/chart-deps-update/SKILL.md` for the full skill definition.

## Prerequisites

- `gh` CLI installed and authenticated
- `helm` installed
- `mage` installed

## Manual Protocol Steps

### 1. Query Latest Versions

Find the latest releases for the sub-services:

```bash
# Backend - get latest release tag (strip 'v' prefix)
gh release list -R Jetscale-ai/backend --limit 1 --json tagName -q '.[0].tagName' | sed 's/^v//'

# Frontend - get latest release tag (strip 'v' prefix)
gh release list -R Jetscale-ai/frontend --limit 1 --json tagName -q '.[0].tagName' | sed 's/^v//'
```

### 2. Update Chart Dependencies

Edit `charts/jetscale/Chart.yaml` with the versions found above.

**Important:** Both `backend-api` and `backend-ws` aliases use the same backend
chart version - update both together.

```yaml
dependencies:
  - name: backend
    alias: backend-api
    version: "X.Y.Z" # <--- Update
  - name: backend
    alias: backend-ws
    version: "X.Y.Z" # <--- Update (same version)
  - name: frontend
    version: "X.Y.Z" # <--- Update
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

The commit message triggers the release workflow.
**Do not bump `version` manually.** CI will handle it.

```bash
# Use "fix" (patch) or "feat" (minor) to trigger the appropriate bump.
git add charts/jetscale/Chart.yaml charts/jetscale/Chart.lock
# Human commits with conventional message
```

## Files to Update

- `charts/jetscale/Chart.yaml` (dependencies only)
- `charts/jetscale/Chart.lock` (regenerate)

## Validation Checklist

- [ ] Latest versions queried successfully
- [ ] Chart dependencies updated (both backend aliases)
- [ ] Chart.lock regenerated
- [ ] `mage validate:envs aws` passes
- [ ] Conventional commit message used
- [ ] CI will handle version bump and commit-back
