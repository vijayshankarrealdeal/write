#!/usr/bin/env bash
# Cloud-agnostic deploy: build locally, ship to any Linux VM via SSH + Docker Compose.
#
# Works on AWS, Azure, GCP, DigitalOcean, Hetzner, OVH, Linode, Vultr, bare metal —
# anything with SSH access where Docker can run.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./deploy.sh                  # build + deploy
#   BOOTSTRAP=1 ./deploy.sh      # also install Docker on a fresh VM
#   SKIP_BUILD=1 ./deploy.sh     # reuse existing build/web and admin-dist
#   LOCAL=1 ./deploy.sh          # bring up the stack on this machine (no SSH)

set -euo pipefail

# ── Load .env (existing env wins, so CI / shell overrides take precedence) ─
if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ ! "$line" =~ = ]] && continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    [[ -n "${!key:-}" ]] && continue
    value="${line#*=}"
    [[ "$value" =~ ^\".*\"$ ]] && value="${value:1:-1}"
    [[ "$value" =~ ^\'.*\'$ ]] && value="${value:1:-1}"
    export "$key=$value"
  done < .env
fi

: "${DOMAIN:?DOMAIN is required (e.g. inkspacex.com or localhost) — set it in .env}"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
NPM_BIN="${NPM_BIN:-npm}"

# ── Local builds (always run on this machine) ─────────────────────────
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "→ Building Flutter web..."
  command -v "$FLUTTER_BIN" >/dev/null || { echo "Missing flutter — set FLUTTER_BIN or install Flutter"; exit 1; }
  "$FLUTTER_BIN" build web --release

  echo "→ Building admin SPA..."
  command -v "$NPM_BIN" >/dev/null || { echo "Missing npm — set NPM_BIN or install Node.js"; exit 1; }
  ( cd admin && "$NPM_BIN" install --silent && "$NPM_BIN" run build )

  echo "→ Stamping version + copying policy files..."
  TS=$(date +%s)
  echo "{\"version\": \"$TS\"}" > build/web/version.json
  cp privacy_policy.html terms_of_service.html build/web/
fi

# ── Local mode: just bring up the stack here ──────────────────────────
if [[ "${LOCAL:-0}" == "1" ]]; then
  echo "→ Bringing up the stack locally..."
  docker compose up -d --build
  docker compose ps
  echo ""
  echo "✅ Local deploy: https://$DOMAIN  (Caddy uses self-signed cert if DOMAIN=localhost)"
  exit 0
fi

# ── Remote mode: ship to SSH_HOST ─────────────────────────────────────
: "${SSH_HOST:?SSH_HOST is required for remote deploy (e.g. ubuntu@1.2.3.4) — set it in .env, or use LOCAL=1}"

SSH_PORT="${SSH_PORT:-22}"
SSH_USER="$(echo "$SSH_HOST" | cut -d@ -f1)"
REMOTE_DIR="${REMOTE_DIR:-/home/$SSH_USER/inkspacex}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$SSH_PORT")
[[ -n "${SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$SSH_KEY")

ssh_exec() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }
rsync_to() { rsync -az -e "ssh ${SSH_OPTS[*]}" "$@"; }

for tool in ssh rsync; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# Bootstrap remote (install Docker if needed).
if [[ "${BOOTSTRAP:-0}" == "1" ]]; then
  echo "→ Bootstrapping Docker on $SSH_HOST..."
  ssh_exec 'bash -s' <<'BOOTSTRAP_EOF'
set -e
if ! command -v docker >/dev/null 2>&1; then
  echo "  installing docker..."
  curl -fsSL https://get.docker.com | sudo sh
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "  installing docker-compose-plugin..."
  sudo apt-get update -qq
  sudo apt-get install -y docker-compose-plugin
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true
echo "  done. (log out + back in if docker still needs sudo)"
BOOTSTRAP_EOF
fi

# Sync to remote.
echo "→ Syncing to $SSH_HOST:$REMOTE_DIR..."
ssh_exec "mkdir -p $REMOTE_DIR/build"

rsync_to --delete \
  --exclude='__pycache__' --exclude='*.pyc' --exclude='.pytest_cache' \
  backend/ "$SSH_HOST:$REMOTE_DIR/backend/"

rsync_to --delete build/web/ "$SSH_HOST:$REMOTE_DIR/build/web/"

rsync_to Caddyfile docker-compose.yml .env "$SSH_HOST:$REMOTE_DIR/"

# Bring up the stack.
echo "→ Bringing up the stack on $SSH_HOST..."
ssh_exec "cd $REMOTE_DIR && (docker compose up -d --build 2>/dev/null || sudo docker compose up -d --build)"

echo "→ Status:"
ssh_exec "cd $REMOTE_DIR && (docker compose ps 2>/dev/null || sudo docker compose ps)"

cat <<EOF

✅ Deployed.
   URL:        https://$DOMAIN
   First run:  Caddy provisions a Let's Encrypt cert in 30–60s.
   Required:   DNS A record for $DOMAIN (and www.$DOMAIN) → VM public IP,
               and ports 80 + 443 reachable from the internet.

Tail logs:     ssh $SSH_HOST 'cd $REMOTE_DIR && docker compose logs -f --tail=50'
Rollout:       ./deploy.sh                 (rebuild + redeploy, data preserved)
Fresh VM:      BOOTSTRAP=1 ./deploy.sh
Local test:    LOCAL=1 DOMAIN=localhost ./deploy.sh
EOF
