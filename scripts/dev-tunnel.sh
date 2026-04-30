#!/usr/bin/env bash
# Persistent SSH tunnel: localhost:{5433,9000,9001} → VM (Postgres + MinIO + console).
# Foreground; Ctrl-C to drop tunnels. Run dev-backend.sh in another shell while this runs.

set -euo pipefail

VM_USER="${VM_USER:-azureuser}"
VM_HOST="${VM_HOST:-20.219.16.30}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/inkspacex_dev}"

[[ -r "$SSH_KEY" ]] || { echo "✗ ssh key not found: $SSH_KEY"; exit 1; }

echo "→ Tunneling to $VM_USER@$VM_HOST:"
echo "    localhost:5433 → VM postgres"
echo "    localhost:9000 → VM minio"
echo "    localhost:9001 → VM minio console"
echo "  (Ctrl-C to stop)"

exec ssh -i "$SSH_KEY" \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -N \
  -L 5433:localhost:5433 \
  -L 9000:localhost:9000 \
  -L 9001:localhost:9001 \
  "$VM_USER@$VM_HOST"
