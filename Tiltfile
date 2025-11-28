# ==========================================================
# JETSCALE STACK ORCHESTRATOR
# ==========================================================

# 1. Config & Safety
allow_k8s_contexts(['kind-jetscale', 'kind-kind'])

# Define Repos
BACKEND_REPO = '../backend'
FRONTEND_REPO = '../frontend'

# 2. Infra Provisioning
local_resource(
  'kind-cluster',
  'kind create cluster --name kind --config kind/kind-config.yaml || true',
  labels=['infra']
)

# 3. Backend Image (Hot Reload Supported)
docker_build(
  'ghcr.io/jetscale-ai/backend-dev',
  context=BACKEND_REPO,
  dockerfile=BACKEND_REPO + '/Dockerfile',
  ignore=[
      BACKEND_REPO + '/venv',
      BACKEND_REPO + '/.git',
      BACKEND_REPO + '/__pycache__'
  ],
  live_update=[
    # Sync python files to /app triggers uvicorn --reload
    sync(BACKEND_REPO, '/app'),
  ]
)

# 4. Frontend Image (Rebuild-on-Change)
# We remove live_update because Nginx cannot hot-reload TypeScript.
# Tilt will rebuild the image (pnpm build) when files change.
docker_build(
  'ghcr.io/jetscale-ai/frontend-dev',
  context=FRONTEND_REPO,
  dockerfile=FRONTEND_REPO + '/Dockerfile',
  ignore=[FRONTEND_REPO + '/node_modules', FRONTEND_REPO + '/.git'],
)

# 5. Deploy Umbrella Chart
yaml = helm(
  './charts/app',
  name='jetscale-stack',
  values=['./charts/app/values.local.yaml'],
  set=[
    'backend-api.image.repository=ghcr.io/jetscale-ai/backend-dev',
    'backend-api.image.tag=latest',
    'backend-api.image.pullPolicy=Never',
    'frontend-web.image.repository=ghcr.io/jetscale-ai/frontend-dev',
    'frontend-web.image.tag=latest',
    'frontend-web.image.pullPolicy=Never'
  ]
)

k8s_yaml(yaml)

# 6. Port Forwards & Organizing
k8s_resource('jetscale-stack-backend-api', port_forwards='8001:8000', labels=['backend'])
# FIX: Expose Frontend on localhost:3000
k8s_resource('jetscale-stack-frontend-web', port_forwards='3000:80', labels=['frontend'])
k8s_resource('jetscale-stack-postgres', port_forwards='5433:5432', labels=['db'])
k8s_resource('jetscale-stack-redis-master', port_forwards='6379:6379', labels=['db'])
