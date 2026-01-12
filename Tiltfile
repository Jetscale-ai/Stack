# Tiltfile
version_settings(constraint='>=0.32.0')

# Optional: make it explicit we're targeting the kind cluster
allow_k8s_contexts('kind-kind')

# ---------------------------
# Images
# ---------------------------
# We keep two modes:
# - `charts/app/values.local.dev.yaml`: Tilt inner-loop (local builds + live_update)
# - `charts/app/values.local.live.yaml`: Live-parity (pull published prod images)

docker_build(
    'ghcr.io/jetscale-ai/backend-dev:tilt',
    '../backend',
    dockerfile='../backend/Dockerfile',
    target='backend-dev',
    live_update=[
        sync('../backend', '/app'),
    ],
)

docker_build(
    'ghcr.io/jetscale-ai/frontend-dev:tilt',
    '../frontend',
    dockerfile='../frontend/Dockerfile',
    target='frontend',  # dev stage in frontend Dockerfile
    live_update=[
        sync('../frontend', '/app'),
    ],
)

# ---------------------------
# Helm: render umbrella chart
# ---------------------------
k8s_yaml(helm(
    'charts/jetscale',
    name='jetscale-stack-local',              # Helm release name
    values=['charts/jetscale/values.local.dev.yaml'],
))

# ---------------------------
# Port-forwards per resource
# ---------------------------
# backend (FastAPI /docs)
k8s_resource(
    'jetscale-stack-local-backend',
    port_forwards=[port_forward(8000, 8000)],  # local: 8000 -> container: 8000
)

# frontend (Nginx serving SPA)
k8s_resource(
    'jetscale-stack-local-frontend',
    port_forwards=[port_forward(3002, 80)],    # local: 3002 -> container: 80
)

# postgres
k8s_resource(
    'jetscale-stack-local-postgres',
    port_forwards=[port_forward(5433, 5432)],  # local: 5433 -> container: 5432
)

# redis
k8s_resource(
    'jetscale-stack-local-redis',
    port_forwards=[port_forward(6379, 6379)],  # local: 6379 -> container: 6379
)
