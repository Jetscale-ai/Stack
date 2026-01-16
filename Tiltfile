# Tiltfile
version_settings(constraint='>=0.32.0')

# Optional: make it explicit we're targeting the kind cluster
allow_k8s_contexts('kind-kind')

# ---------------------------
# Images
# ---------------------------
# We keep two modes:
# - `charts/jetscale/values.local.dev.yaml`: Tilt inner-loop (local builds + live_update)
# - `charts/jetscale/values.local.live.yaml`: Live-parity (pull published prod images)

backend_dir = '../Backend'
frontend_dir = '../Frontend'
# Support both capitalized and lowercased sibling repo names (Linux is case-sensitive).
if not os.path.exists(backend_dir):
    backend_dir = '../backend'
if not os.path.exists(frontend_dir):
    frontend_dir = '../frontend'

docker_build(
    'ghcr.io/jetscale-ai/backend-dev:tilt',
    backend_dir,
    dockerfile=backend_dir + '/Dockerfile',
    target='backend-dev',
    live_update=[
        sync(backend_dir, '/app'),
    ],
)

docker_build(
    'ghcr.io/jetscale-ai/frontend-dev:tilt',
    frontend_dir,
    dockerfile=frontend_dir + '/Dockerfile',
    target='frontend',  # runtime stage in frontend Dockerfile (nginx)
    live_update=[
        sync(frontend_dir, '/app'),
    ],
)

# ---------------------------
# Helm: render umbrella chart
# ---------------------------
k8s_yaml(helm(
    'charts/jetscale',
    name='jetscale-local',              # Helm release name
    values=['charts/jetscale/values.local.dev.yaml'],
))

# ---------------------------
# Port-forwards per resource
# ---------------------------
# backend-api (FastAPI /docs)
k8s_resource(
    'jetscale-local-backend-api',
    port_forwards=[port_forward(8000, 8000)],  # local: 8000 -> container: 8000
)

# backend-ws
k8s_resource(
    'jetscale-local-backend-ws',
    port_forwards=[port_forward(8001, 8001)],  # local: 8000 -> container: 8000
)

# frontend (Nginx serving SPA)
k8s_resource(
    'jetscale-local-frontend',
    port_forwards=[port_forward(8080, 80)],    # local: 3002 -> container: 80
)

# postgres
k8s_resource(
    'jetscale-local-postgres',
    port_forwards=[port_forward(5432, 5432)],  # local: 5433 -> container: 5432
)

# redis
k8s_resource(
    'jetscale-local-redis',
    port_forwards=[port_forward(6379, 6379)],  # local: 6379 -> container: 6379
)
