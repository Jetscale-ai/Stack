# Stack Roadmap

## Phase 1: Foundation (Completed)

- [x] Establish `Jetscale-ai/Stack`.
- [x] **Chart Synthesis:** Implemented missing subcharts (`backend-api`, `frontend-web`) and vendored into `charts/app`.
- [x] **Orchestration:** Implemented `Tiltfile` using native `helm()` function for reliable local deployments.
- [x] **Dependency Stabilization:** Replaced deprecated Bitnami images with official Alpine/Debian images (Postgres 15, Redis 7).

## Phase 2: Adoption (In Progress)

- [ ] **Team Migration:** Move developers from `docker-compose up` to `tilt up`.
- [x] **Developer Experience:** Established consistent port mapping (Frontend: 3000, Backend: 8000) via Tilt resources.
- [x] **Connectivity:** Verified `VITE_API_BASE_URL` connectivity between Frontend and Backend in Kind.
- [x] **Nginx Architecture:** Standardized Frontend container with explicit `nginx.conf` and correct build context.

## Phase 3: CI & Live Architecture (Implemented)

- [x] Implement `skaffold.yaml` with profiles for `ci-kind`, `preview`, and `live`.
- [x] Configure `values.live.yaml` for HA AWS deployment.
- [x] Define GitHub Workflows for CI (`ci-kind.yaml`) and Previews (`deploy-preview.yaml`).

## Phase 4: Operational Hardening (Next)

- [ ] **Automation:** Update `magefile.go` to wrap the full boot sequence (`kind create` + `helm dep build` + `tilt up`).
- [ ] **Secret Management:** Replace `values.secret.example.yaml` with K8s Secrets or External Secrets Operator.
- [ ] **Observability:** Integrate Prometheus/Grafana into `charts/app` (conditional).
- [ ] **Ingress Automation:** Verify `external-dns` and `cert-manager` integration in Live profile.
