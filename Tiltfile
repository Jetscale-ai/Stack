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

# Support case-insensitive backend/frontend directory names
def find_sibling_dir(base_name):
    """Find sibling directory case-insensitively by trying common variations."""
    parent_dir = os.path.dirname(os.getcwd())

    # Try common case variations
    variations = [
        base_name,                    # backend
        base_name.capitalize(),       # Backend
        base_name.upper(),           # BACKEND
        base_name.lower(),           # backend (already covered)
    ]

    for variation in variations:
        candidate = os.path.join(parent_dir, variation)
        if os.path.exists(candidate):
            return candidate

    return None

backend_dir = find_sibling_dir('backend')
if not backend_dir:
    fail('Could not find backend directory (tried: backend, Backend, BACKEND)')

frontend_dir = find_sibling_dir('frontend')
if not frontend_dir:
    fail('Could not find frontend directory (tried: frontend, Frontend, FRONTEND)')

docker_build(
    'ghcr.io/jetscale-ai/backend-dev:tilt',
    backend_dir,
    dockerfile=backend_dir + '/Dockerfile',
    target='backend-dev',
    platform='linux/amd64',
    live_update=[
        sync(backend_dir, '/app'),
    ],
)

docker_build(
    'ghcr.io/jetscale-ai/frontend-dev:tilt',
    frontend_dir,
    dockerfile=frontend_dir + '/Dockerfile',
    target='frontend',  # runtime stage in frontend Dockerfile (nginx)
    platform='linux/amd64',
    live_update=[
        sync(frontend_dir, '/app'),
    ],
)

# ---------------------------
# ConfigMap: Backend .env file (for local dev only)
# ---------------------------
backend_env_file = backend_dir + '/.env'
env_content = ""
if os.path.exists(backend_env_file):
    env_content = str(read_file(backend_env_file))

# Always create the ConfigMap so pods don't fail to mount when the local backend
# repo doesn't have a `.env` file yet.
# (values.local.dev.yaml mounts this unconditionally.)
indented_env = '\n'.join(['    ' + line for line in env_content.split('\n')])
k8s_yaml(blob("""apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-env-file
data:
  .env: |
""" + indented_env))

# ---------------------------
# Helm: render umbrella chart
# ---------------------------
k8s_yaml(helm(
    'charts/jetscale',
    name='jetscale-local', # Helm release name
    values=['charts/jetscale/values.local.dev.yaml'],
))

# ---------------------------
# Port-forwards per resource
# ---------------------------
# backend-api (FastAPI /docs)
k8s_resource(
    'jetscale-local-backend-api',
    port_forwards=[port_forward(8000, 8000)],
)

# backend-ws
k8s_resource(
    'jetscale-local-backend-ws',
    port_forwards=[port_forward(8001, 8001)],
)

# frontend (Nginx serving SPA)
k8s_resource(
    'jetscale-local-frontend',
    port_forwards=[port_forward(8080, 80)],
)

# postgres
k8s_resource(
    'jetscale-local-postgres',
    port_forwards=[port_forward(5432, 5432)],
)

# redis
k8s_resource(
    'jetscale-local-redis',
    port_forwards=[port_forward(6379, 6379)],
)
