# Helm & Platform Roadmap (Backend)

## The Shift

We are deprecating `docker-compose.yml` in favor of the [Jetscale-ai/Stack](https://github.com/Jetscale-ai/Stack) repository.

## Why?

Our `docker-compose` setup was drifting from how we run in EKS. By using **Tilt**, we run the exact same Helm charts locally that we run in the live environment, but with the Developer Experience (DX) of hot-reloading.

## Your New Workflow

1. **Do not run** `docker compose up`.

2. Go to `../stack` and run `tilt up`.

3. Edit python files in this repo as usual.

4. **Tilt** syncs your changes into the K8s pod instantly.

5. `uvicorn` reloads automatically.

## Configuration

- Environment variables are now managed in `stack/charts/app/values.local.yaml`.

- If you add a new `JETSCALE_*` var, add it there.

