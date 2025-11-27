# ==========================================================
# JETSCALE STACK ORCHESTRATOR
# ==========================================================

# 1. Load Extensions
load('ext://helm_remote', 'helm_remote')

# 2. Config & Constants
allow_k8s_contexts('kind-jetscale') # Safety check

# Define Repos (Assuming they are siblings to this folder)
BACKEND_REPO = '../backend'
FRONTEND_REPO = '../frontend'

# 3. Create Kind Cluster (if not exists)
local_resource(
  'kind-cluster',
  'kind create cluster --name jetscale --config kind/kind-config.yaml || true',
  labels=['infra']
)

# 4. Build Images (Delegated)
# We build locally tagged images to use in the cluster
docker_build(
  'ghcr.io/jetscale-ai/backend-dev',
  context=BACKEND_REPO,
  dockerfile=BACKEND_REPO + '/Dockerfile',
  live_update=[
    # Sync python files directly into container (Hot Reload)
    sync(BACKEND_REPO, '/app'),
    # Ignore virtualenv and git
    ignore(BACKEND_REPO + '/venv'),
    ignore(BACKEND_REPO + '/.git'),
  ],
  # Only trigger build if Dockerfile changes (since we mount code)
  only=[BACKEND_REPO + '/Dockerfile', BACKEND_REPO + '/requirements.txt']
)

# 5. Deploy Umbrella Chart
helm_remote(
  'jetscale-stack',
  chart='./charts/app',
  values=['./charts/app/values.local.yaml'],
  set=[
    # Force use of the locally built image
    'backend-api.image.repository=ghcr.io/jetscale-ai/backend-dev',
    'backend-api.image.tag=latest',
    'backend-api.image.pullPolicy=Never'
  ],
  labels=['platform']
)

# 6. Port Forwards (Convenience)
k8s_resource('jetscale-stack-backend-api', port_forwards='8000:8000', labels=['backend'])
k8s_resource('jetscale-stack-postgres', port_forwards='5433:5432', labels=['db'])
k8s_resource('jetscale-stack-redis-master', port_forwards='6379:6379', labels=['db'])

# 7. Local Secrets Injection (Optional)
# You can read your local .env and inject specific secrets if needed
# local_env = read_env_file(BACKEND_REPO + '/.env')

