# InkSpaceX

Flutter app + FastAPI backend + Postgres + S3-compatible object storage, all
fronted by Caddy with automatic HTTPS.

## Stack

| Layer       | Service                                              |
|-------------|------------------------------------------------------|
| Web SPA     | Flutter web (`build/web`, served by Caddy)           |
| Admin SPA   | React/Vite (`backend/admin-dist`, served by FastAPI) |
| API         | FastAPI / Uvicorn (`backend/`)                       |
| Database    | Postgres 16 (or any managed Postgres via env)        |
| Object store| MinIO (or any S3-compatible: R2 / S3 / Spaces / GCS) |
| Edge        | Caddy 2 (TLS, reverse-proxy, static files)           |

## Deployment model

Single source of truth for all runtime config: a `.env` file. In CI, that file
is reconstructed from the `DOTENV` GitHub secret. Locally, you create your own.

The deploy itself is just **rsync + `docker compose up -d --build`** to any
Linux VM with SSH access — no per-cloud glue. Works identically on AWS / Azure
/ GCP / DigitalOcean / Hetzner / OVH / Linode / Vultr / bare metal.

## Automated deploy from `main` (GitHub Actions)

Pushing to `main` triggers `.github/workflows/deploy.yml`, which:
1. Builds Flutter web and the admin SPA on the runner.
2. Reconstructs `.env` from the `DOTENV` GitHub secret.
3. Loads the deploy SSH key from the `SSH_PRIVATE_KEY` secret.
4. SSHes into `SSH_HOST` and runs `./deploy.sh`.

### Required GitHub Secrets

| Secret            | What it is                                                                |
|-------------------|---------------------------------------------------------------------------|
| `DOTENV`          | The full contents of your `.env` file (DOMAIN, all passwords, OpenAI key).|
| `SSH_HOST`        | `user@host` for the deploy target, e.g. `ubuntu@1.2.3.4`.                 |
| `SSH_PRIVATE_KEY` | ED25519 private key. Public counterpart is in `.github/deploy-key.pub`.   |

Set or update them with `gh`:

```sh
gh secret set DOTENV < .env                          # update env config
gh secret set SSH_HOST -b "ubuntu@your.vm.ip"        # set deploy target
gh secret set SSH_PRIVATE_KEY < /path/to/private-key # rotate deploy key
```

### Public deploy key (add to your VM)

The matching public key is committed at [.github/deploy-key.pub](.github/deploy-key.pub).
After spinning up your VM, append it to the deploy user's `authorized_keys`:

```sh
ssh you@vm.ip "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < .github/deploy-key.pub
```

### Manually triggering a deploy

```sh
gh workflow run Deploy
gh run watch
```

## VM setup checklist

1. Spin up a Linux VM (Ubuntu 22.04+). Cheapest viable for ~5k users: DO `s-1vcpu-2gb` ($12/mo), Hetzner CX22 (~€4/mo), Vultr `vc2-1c-2gb` ($12/mo).
2. Open ports **80** and **443** to the internet.
3. Point your domain's **A record** (root + `www`) at the VM's public IP.
4. Append `.github/deploy-key.pub` to `~/.ssh/authorized_keys` on the VM.
5. Update GitHub secrets: `gh secret set SSH_HOST -b "user@ip"`.
6. First deploy needs Docker on the VM. Either run once locally with `BOOTSTRAP=1 ./deploy.sh`, or SSH in and `curl -fsSL https://get.docker.com | sudo sh`.
7. `gh workflow run Deploy` — Caddy provisions a Let's Encrypt cert within ~60s.

## .env reference

```sh
# Public domain (Caddy substitutes {$DOMAIN} in Caddyfile at startup)
DOMAIN=inkspacex.com

# Postgres (self-hosted) — or set DATABASE_URL directly for managed Postgres
POSTGRES_USER=inkspacex
POSTGRES_PASSWORD=<32+ random hex>
POSTGRES_DB=inkspacex

# MinIO (self-hosted) — or replace with S3 / R2 / Spaces / GCS values
MINIO_ROOT_USER=inkspacex
MINIO_ROOT_PASSWORD=<32+ random hex>
MINIO_PUBLIC_URL=https://inkspacex.com/storage

# App secrets
JWT_SECRET=<openssl rand -hex 32>
GOOGLE_CLIENT_ID=<from Google Cloud Console>
CORS_ORIGINS=https://inkspacex.com,https://www.inkspacex.com

# Azure OpenAI (only if AI features used)
AZURE_OPENAI_API_KEY=<rotate any leaked key first>
AZURE_OPENAI_ENDPOINT=https://clarity-analytic.cognitiveservices.azure.com/
AZURE_OPENAI_API_VERSION=2024-12-01-preview
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-5.4-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-ada-002
```

## Manual / local deploys

```sh
# Local stack on this machine (DOMAIN=localhost gets Caddy's self-signed cert)
LOCAL=1 ./deploy.sh

# Manual SSH deploy from your laptop (skips GitHub Actions)
SSH_HOST=ubuntu@1.2.3.4 ./deploy.sh

# First-time deploy on a fresh VM (installs Docker first)
BOOTSTRAP=1 SSH_HOST=ubuntu@1.2.3.4 ./deploy.sh
```

| Env / flag        | Effect                                             |
|-------------------|----------------------------------------------------|
| `BOOTSTRAP=1`     | Install Docker on a fresh VM before deploying     |
| `SKIP_BUILD=1`    | Reuse existing `build/web/` and `admin-dist/`     |
| `LOCAL=1`         | Bring up the stack on this machine (no SSH)       |
| `SSH_KEY=path`    | Use a specific private key                        |
| `SSH_PORT=N`      | Non-default SSH port                              |
| `REMOTE_DIR=path` | Where to install on the VM (default: `~/inkspacex`)|

## Swapping in managed services

The architecture is intentionally vanilla so you can swap pieces out as you
grow. None of the application code changes — just `.env` and which services
are in `docker-compose.yml`.

### Use a managed Postgres (Neon / Supabase / RDS / etc.)

1. Remove the `postgres:` service block from `docker-compose.yml`.
2. In `.env`, set `DATABASE_URL` to the managed connection string (must use the
   `postgresql+asyncpg://` driver scheme).
3. Add `DATABASE_URL` to the `fastapi` service's `environment:` block in
   `docker-compose.yml`.

### Use S3 / R2 / DO Spaces / GCS instead of MinIO

1. Remove the `minio:` and `minio-init:` service blocks from `docker-compose.yml`.
2. In `.env`, set `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`,
   `MINIO_BUCKET`, `MINIO_USE_SSL=true`, `MINIO_PUBLIC_URL`.
3. Optionally update Caddyfile to drop the `/storage/*` reverse-proxy.

## Project layout

```
.
├── .github/
│   ├── workflows/deploy.yml ← CI deploy on push to main
│   └── deploy-key.pub       ← public half of the GitHub Actions deploy key
├── deploy.sh                ← cloud-agnostic deploy entrypoint
├── docker-compose.yml       ← stack definition (postgres, minio, fastapi, caddy)
├── Caddyfile                ← TLS + reverse-proxy ({$DOMAIN} substituted at runtime)
├── backend/                 ← FastAPI source (Dockerfile, requirements, app/)
│   └── admin-dist/          ← built admin SPA (output of admin/ build)
├── admin/                   ← admin SPA source (React + Vite + Tailwind)
├── lib/                     ← Flutter app source (mobile + web)
├── web/                     ← Flutter web template (index.html, manifest.json, icons)
└── build/web/               ← built Flutter web (built by deploy.sh, served by Caddy)
```

## Operations

```sh
# Tail all service logs
ssh $SSH_HOST 'cd ~/inkspacex && docker compose logs -f --tail=100'

# Restart a single service
ssh $SSH_HOST 'cd ~/inkspacex && docker compose restart fastapi'

# Backup Postgres
ssh $SSH_HOST 'docker exec inkspacex-postgres-1 pg_dump -U inkspacex inkspacex' > backup-$(date +%F).sql

# Scale up: stop the stack, resize the VM in the cloud console, start it again.
# Stack supports vertical scaling cleanly up to ~5k DAU on a single 4-vCPU box.
```
