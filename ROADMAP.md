# Stack Roadmap

## 0. ArgoCD + Fleet Impact

This repo builds the `jetscale` **OCI Helm chart**. **It does not own deployment state.**

- **Deployments:** change `../fleet/clusters/<name>/values.yaml` (version pins + environment config); ArgoCD syncs.
- **Patterns:** maintained in `../catalog` (Blueprint charts rendering Argo `Application` objects).
- **Infra/Drivers:** provisioned in `../iac` (EKS + controllers + Argo bootstrap).

## Phase 1: Foundation (Completed)

- [x] Establish `Jetscale-ai/Stack`.
- [x] **Chart Synthesis:** Implemented missing subcharts (`backend`, `frontend`).
- [x] **Orchestration:** Implemented `Tiltfile` and `skaffold.yaml`.

## Phase 2: Adoption (Completed)

- [x] **Developer Experience:** Consistent port mapping (3000/8000).
- [x] **Connectivity:** Verified `VITE_API_BASE_URL` connectivity in Kind.

## Phase 3: CI Architecture (Completed)

- [x] **CI Profiles:** Established `ci-kind` vs `local-kind` in Skaffold.

- [x] **GitHub Workflows:** Implemented `ci-kind` (E2E) and `ci-validate` (Preflight).

## Phase 4: Supply Chain Hardening (Current)

- [x] **OCI Artifacts:** Migrated Chart dependencies to `oci://ghcr.io`.
- [x] **Validation Layer:** Implemented `mage validate:envs` and pre-commit hooks.
- [x] **Dependency Locking:** Enforced `Chart.lock` integrity.
- [ ] **Secret Management:** Implement `ExternalSecrets` in Helm + `ClusterSecretStore` in Terraform.

## Phase 5: GitOps Adoption (Current)

- [ ] **Docs boundary:** ensure chart READMEs describe **local Helm usage only**; production installs are via ArgoCD from `../fleet`.
- [ ] **Argo-friendly chart contract:** keep templates idempotent; avoid CRD installs; rely on infra-provided controllers.

- [ ] **Release automation:** publish the `jetscale` OCI chart from CI on tags and keep `Chart.lock` in sync.
- [ ] **Interface stability:** maintain a small, well-documented values surface that `../fleet` can safely own (domains, replicas, ingress toggles).

## Phase 6: The Sovereign Pipeline (GH Actions)

- [ ] **Dynamic State Logic:** Update CI to handle `prs/pr-N/terraform.tfstate`.

- [ ] **DNS Automation:** Implement `pr-N.jetscale.ai` dynamic registration via ExternalDNS.
- [ ] **The Janitor:** Create scheduled GitHub Action to destroy orphaned PR clusters.
- [ ] **App Deployment:** update Fleet version pins (PR-driven) and let ArgoCD sync; never run `helm install` for live clusters.

## Phase 7: GitOps Evolution (Future)

- [ ] **The Mothership:** Establish `tools.jetscale.ai` cluster.
- [ ] **Infrastructure Ops:** Migrate Terraform execution to **Atlantis** running on `tools`.
- [ ] **App Ops:** Migrate Helm deployment to **ArgoCD** running on `tools`.
  - [ ] Adopt "App-of-Apps" or ApplicationSet pattern for multi-cluster management.
