# Stack Roadmap

## Phase 1: Foundation (Completed)

- [x] Establish `Jetscale-ai/Stack`.
- [x] Implement `charts/app` wrapping Backend, Frontend, Postgres (Bitnami), Redis (Bitnami).
- [x] Create `values.local.yaml` mapping all `JETSCALE_*` vars.
- [x] Implement `Tiltfile` with `live_update` for hot-reloading (Supported via `mage dev`).

## Phase 2: Adoption (In Progress)

- [ ] **Team Migration:** Move developers from `docker-compose up` to `tilt up`.
- [x] Verify `VITE_API_BASE_URL` connectivity in local loop (mapped via NodePort 30000).
- [x] Provide granular Mage E2E targets for Local, CI, Preview, Live loops.

## Phase 3: CI & Live Architecture (Implemented)

- [x] Implement `skaffold.yaml` with profiles for `ci-kind`, `preview`, and `live`.
- [x] Configure `values.live.yaml` for HA AWS deployment.
- [x] Define GitHub Workflows for CI (`ci-kind.yaml`) and Previews (`deploy-preview.yaml`).

## Phase 4: Operational Hardening (Next)

- [ ] **Secret Management:** Replace `values.secret.example.yaml` with K8s Secrets or External Secrets Operator.
- [ ] **Observability:** Integrate Prometheus/Grafana into `charts/app` (conditional).
- [ ] **Ingress Automation:** Verify `external-dns` and `cert-manager` integration in Live profile.
