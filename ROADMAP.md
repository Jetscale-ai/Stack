# Stack Roadmap

## Phase 1: Foundation (Completed)
- [x] Establish `Jetscale-ai/Stack`.
- [x] **Chart Synthesis:** Implemented missing subcharts (`backend-api`, `frontend-web`).
- [x] **Orchestration:** Implemented `Tiltfile` and `skaffold.yaml`.

## Phase 2: Adoption (Completed)
- [x] **Developer Experience:** Consistent port mapping (3000/8000).
- [x] **Connectivity:** Verified `VITE_API_BASE_URL` connectivity in Kind.
- [x] **Container Hardening:** Standardized on Alpine/Debian images.

## Phase 3: CI & Live Architecture (Completed)
- [x] **CI Profiles:** Established `ci-kind` vs `local-kind` in Skaffold.
- [x] **GitHub Workflows:** Implemented `ci-kind` (E2E) and `ci-validate` (Preflight).
- [x] **Preview Envs:** Defined `envs/preview` for ephemeral deployments.

## Phase 4: Supply Chain Hardening (Current)
- [x] **OCI Artifacts:** Migrated Chart dependencies to `oci://ghcr.io`.
- [x] **Validation Layer:** Implemented `mage validate:envs` and pre-commit hooks.
- [x] **Dependency Locking:** Enforced `Chart.lock` and `go.sum` integrity.
- [x] **Pipeline Resilience:** Implemented Liveness Probes and strict `kubectl wait` logic to eliminate CI flakes.
- [ ] **Secret Management:** Replace `values.secret.example.yaml` with External Secrets Operator (ESO).

## Phase 5: Observability & Day 2 Ops (Next)
- [ ] **Metrics:** Integrate Prometheus/Grafana subcharts.
- [ ] **Tracing:** Implement OpenTelemetry sidecars in `charts/app`.
- [ ] **Ingress Automation:** Verify `external-dns` and `cert-manager` integration in Live profile.
