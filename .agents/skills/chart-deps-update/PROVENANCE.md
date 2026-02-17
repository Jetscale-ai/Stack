# Provenance: chart-deps-update

## Intent

Reliably check for and update backend/frontend chart versions in the JetScale
umbrella chart, ensuring supply chain integrity through proper lockfile
regeneration and validation.

## Discovery

- **Date:** 2026-02-17
- **Queries:**
  - `helm dependency update automation`
  - `chart version bump workflow`
  - `github packages version discovery`
- **Indices searched:**
  - Internal: `agents/upversion.md` (existing protocol)
  - Internal: `governance/.agents/skills/upsert-skill/` (skill pattern)

## Candidates Considered

| Source                    | Type     | Score | Notes                                           |
| ------------------------- | -------- | ----- | ----------------------------------------------- |
| `agents/upversion.md`     | Internal | 90    | Existing protocol, needs automation enhancement |
| `governance/upsert-skill` | Internal | N/A   | Pattern reference for skill structure           |

## Decision

**Authored** - Enhanced existing `agents/upversion.md` protocol with:

1. Automated version discovery via `gh release list` (avoids `read:packages` scope)
2. Helper script for one-command updates
3. Structured skill format following governance patterns
4. Explicit handling of dual backend aliases

## Sources & Attribution

- **agents/upversion.md** - Original protocol steps and validation checklist
- **governance/.agents/skills/upsert-skill/SKILL.md** - Skill structure pattern
- **AGENTS.md** - Supply Chain Integrity invariant (Section 3.1)

## Local Modifications

1. **Version discovery method** - Changed from packages API to releases API
   (works without `read:packages` scope)
2. **Script automation** - Added `scripts/check-chart-updates.sh` for
   one-command workflow
3. **Dual alias handling** - Explicit documentation that `backend-api` and
   `backend-ws` must be updated together
4. **Skill format** - Structured as `.agents/skills/` following governance
   pattern

## Upgrade Notes

This skill should be updated when:

1. Chart structure changes (new dependencies added)
2. CI/CD workflow changes (different versioning strategy)
3. Registry authentication method changes

To verify skill is current:

```bash
# Check if Chart.yaml structure matches skill assumptions
grep -E '(name|alias|version):' charts/jetscale/Chart.yaml

# Verify gh release API still works
gh release list -R Jetscale-ai/backend --limit 1
```
