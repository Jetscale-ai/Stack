# Helm & Platform Roadmap (Frontend)

## The Shift

We are moving to a Platform-First workflow managed by [Jetscale-ai/Stack](https://github.com/Jetscale-ai/Stack).

## Your New Workflow

You have two robust options:

### Mode A: Fast & Focused (Recommended)

1. Run `npm run dev` in this repo.

2. Point your `.env.local` to the shared dev environment or local stack:

   `VITE_API_BASE_URL=http://localhost:8080/api/v1`

### Mode B: Full Stack Integration

1. Go to `../stack` and run `tilt up`.

2. This boots the Backend, Redis, and Postgres in a local Kubernetes cluster.

3. Your changes to frontend code are synced instantly if you run the frontend via Tilt (optional).

## CI/CD

- PRs now trigger a **Preview Environment** on EKS.

- You will get a URL like `https://pr-123.app.jetscale.ai` to test against a real backend before merge.

